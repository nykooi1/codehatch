import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

// ── reading Codex's own files (read-only) ──
// Codex has no list of open sessions, so: find running codex processes, see which session log each has open,
// and look that session up in Codex's local database for its name, folder and branch.
enum Codex {
    static let home = Loader.home.appendingPathComponent(".codex")
    static var logOf: [Int32: String] = [:]

    static func load() -> [Session] {
        let pids = running(); guard !pids.isEmpty else { return [] }
        var db: OpaquePointer? = nil
        if let path = (try? FileManager.default.contentsOfDirectory(atPath: home.path))?.filter({ $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }).sorted().last {
            if sqlite3_open_v2("file:\(home.path)/\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) != SQLITE_OK { sqlite3_close(db); db = nil }
        }
        defer { if db != nil { sqlite3_close(db) } }
        var out: [Session] = [], seen: Set<String> = []
        for pid in pids {
            let open = files(of: pid)
            // Older Codex kept its session log open, so the log could be read straight off the process. Newer Codex
            // hands the writing to a background service, and the process you see holds nothing. Then the log is
            // found by folder: the newest one for this folder that has been written to since this process started.
            let found = open.log ?? logOf[pid] ?? open.cwd.flatMap { newestLog(in: $0, since: started(pid), taken: Set(logOf.values)) }
            guard let log = found else {
                // Running, but nothing has been asked yet, so there is no log to name it by.
                guard let cwd = open.cwd, FileManager.default.fileExists(atPath: cwd), cwd != "/" else { continue }
                var s = Session(id: "codex-pid-\(pid)", pid: pid, cwd: cwd, status: "idle", updatedAt: Date().timeIntervalSince1970 * 1000, title: "New session")
                s.tool = "codex"; s.empty = true; out.append(s); continue
            }
            logOf[pid] = log
            let id = String(((log as NSString).lastPathComponent as NSString).deletingPathExtension.suffix(36))
            guard !seen.contains(id) else { continue }; seen.insert(id)
            var title = firstAsked(log) ?? "Untitled session", cwd = open.cwd ?? "", branch: String? = nil, recap: String? = nil
            if let db, let row = thread(db, id) {
                title = row.title; if !row.cwd.isEmpty { cwd = row.cwd }; branch = row.branch
                if let p = row.preview, !p.isEmpty { recap = p } else if let f = row.first, !f.isEmpty { recap = "First asked: " + f }
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: log)
            let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
            var s = Session(id: "codex-" + id, pid: pid, cwd: cwd, status: working(log) ? "busy" : "idle", updatedAt: modified * 1000, title: title)
            s.tool = "codex"; s.branch = branch; s.recap = recap
            let said = lastSaid(log); s.lastAsked = said.asked; s.lastReply = said.reply; s.replyIsNewer = said.newer
            out.append(s)
        }
        return out
    }

    /// Process numbers of running Codex programs.
    /// Listing every process on the Mac is the dearest thing a reload does, so the answer is kept for ten seconds.
    static var runningCache: (at: Double, pids: [Int32]) = (0, [])
    static func running() -> [Int32] {
        // Finding Codex sessions means listing every process on the Mac, the dearest thing a reload does. Someone who
        // has never used Codex has no ~/.codex folder, and for them it is skipped altogether.
        guard FileManager.default.fileExists(atPath: Loader.home.appendingPathComponent(".codex").path) || ProcessInfo.processInfo.environment["CODEHATCH_TEST_PIDS"] != nil else { return [] }
        let now = Date().timeIntervalSince1970
        if now - runningCache.at < 10 { return runningCache.pids.filter { kill($0, 0) == 0 } }
        let found = scan()
        runningCache = (now, found)
        return found
    }
    static func scan() -> [Int32] {
        // Tests name the pretend Codex processes they started, so real ones on the machine are not picked up.
        if let only = ProcessInfo.processInfo.environment["CODEHATCH_TEST_PIDS"] { return only.split(separator: ",").compactMap { Int32($0) }.filter { kill($0, 0) == 0 } }
        let lines = shell("/bin/ps", ["-axo", "pid=,comm="]).split(separator: "\n")
        return lines.compactMap { line -> Int32? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]) else { return nil }
            let path = String(t[sp...]).trimmingCharacters(in: .whitespaces)
            // Codex's own background service is also a program called codex. It is not a session.
            if path.contains("/app-server-daemon/") { return nil }
            let name = (path as NSString).lastPathComponent
            return name == "codex" || name.hasPrefix("codex-") ? pid : nil
        }
    }
    /// When a process started, in seconds since 1970.
    static func started(_ pid: Int32) -> Double {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return Double(info.kp_proc.p_starttime.tv_sec)
    }
    /// The folder each session log was started in, read once from the log's first line.
    static var folderOf: [String: String] = [:]
    /// The most recently written session log for a folder, among those written since a given moment and not
    /// already matched to another process.
    static func newestLog(in cwd: String, since: Double, taken: Set<String>) -> String? {
        let root = home.appendingPathComponent("sessions")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var best: (path: String, at: Double)? = nil
        let want = (cwd as NSString).resolvingSymlinksInPath
        for case let f as URL in walker where f.pathExtension == "jsonl" {
            guard let at = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970, at >= since - 2,
                  !taken.contains(f.path), at > (best?.at ?? 0) else { continue }
            if folderOf[f.path] == nil, let h = try? FileHandle(forReadingFrom: f) {
                let head = h.readData(ofLength: 4000); try? h.close()
                if let r = head.range(of: Data("\"cwd\":\"".utf8)), let q = head[r.upperBound...].firstIndex(of: UInt8(ascii: "\"")) {
                    folderOf[f.path] = (String(decoding: head[r.upperBound..<q], as: UTF8.self) as NSString).resolvingSymlinksInPath
                }
            }
            if folderOf[f.path] == want { best = (f.path, at) }
        }
        return best?.path
    }
    /// The session log a Codex process has open, and the folder it is running in.
    static func files(of pid: Int32) -> (log: String?, cwd: String?) {
        var log: String? = nil, cwd: String? = nil, fd = ""
        for line in shell("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-Fn"]).split(separator: "\n") {
            if line.hasPrefix("f") { fd = String(line.dropFirst()) }
            else if line.hasPrefix("n") {
                let name = String(line.dropFirst())
                if fd == "cwd" { cwd = name }
                if name.hasPrefix(home.path + "/sessions/") && name.hasSuffix(".jsonl") { log = name }
            }
        }
        return (log, cwd)
    }
    /// The first thing typed in a session, from its log: a name for it when Codex's own records cannot be read.
    /// The last thing you typed in a Codex session and the last thing it answered, from the end of its log.
    /// The answer is kept until the log grows, so an idle session costs nothing to look at again.
    static var saidCache: [String: (size: UInt64, asked: String?, reply: String?, newer: Bool)] = [:]
    static func lastSaid(_ log: String) -> (asked: String?, reply: String?, newer: Bool) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: log))?[.size] as? UInt64) ?? 0
        if let c = saidCache[log], c.size == size { return (c.asked, c.reply, c.newer) }
        var asked: String? = nil, reply: String? = nil, newer = false
        if let h = FileHandle(forReadingAtPath: log) {
            defer { try? h.close() }
            if size > 400_000 { try? h.seek(toOffset: size - 400_000) }
            let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
            for line in text.split(separator: "\n") where line.contains("\"response_item\"") && line.contains("\"message\"") {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let p = o["payload"] as? [String: Any],
                      p["type"] as? String == "message", let role = p["role"] as? String, let parts = p["content"] as? [[String: Any]] else { continue }
                let words = parts.compactMap { $0["text"] as? String }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                // Codex also files its own notes to the model as "user" messages; those start with a tag.
                guard !words.isEmpty, !words.hasPrefix("<") else { continue }
                if role == "user" { asked = Loader.flat(words); newer = false }
                else if role == "assistant" { reply = Loader.flat(words); newer = true }
            }
        }
        func short(_ t: String?) -> String? { t.map { $0.count > 300 ? String($0.prefix(299)) + "…" : $0 } }
        saidCache[log] = (size, short(asked), short(reply), newer)
        return (short(asked), short(reply), newer)
    }
    static func firstAsked(_ log: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: log) else { return nil }
        defer { try? h.close() }
        for line in String(decoding: h.readData(ofLength: 200_000), as: UTF8.self).split(separator: "\n") where line.contains("\"user_message\"") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let p = o["payload"] as? [String: Any],
                  let m = p["message"] as? String else { continue }
            let one = m.split(separator: "\n").first.map(String.init) ?? m
            if !one.isEmpty { return one.count > 70 ? String(one.prefix(69)) + "…" : one }
        }
        return nil
    }
    /// Working if the log's last "task started" has no "task complete" after it.
    static func working(_ log: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: log) else { return false }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 300_000 ? size - 300_000 : 0)
        let tail = h.readDataToEndOfFile()
        let started = tail.range(of: Data("\"task_started\"".utf8), options: .backwards)?.lowerBound
        let done = tail.range(of: Data("\"task_complete\"".utf8), options: .backwards)?.lowerBound
        guard let started else { return false }
        return done == nil || started > done!
    }
    static func thread(_ db: OpaquePointer, _ id: String) -> (title: String, cwd: String, branch: String?, preview: String?, first: String?)? {
        var st: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, "select coalesce(nullif(name,''), title), cwd, git_branch, preview, first_user_message from threads where id = ?", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        func col(_ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
        let raw = (col(0) ?? "Untitled session").split(separator: "\n").first.map(String.init) ?? "Untitled session"
        return (raw.count > 70 ? String(raw.prefix(69)) + "…" : raw, col(1) ?? "", col(2), col(3), col(4))
    }
    static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
