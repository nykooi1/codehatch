// Throwaway test: a pill at the top of the screen that drops down a list of live Claude Code sessions.
// Not the real app. It exists to show what building and running a native Mac app feels like.
import AppKit
import SwiftUI
import Carbon.HIToolbox
import Speech
import AVFoundation
import SQLite3

/// Notes for working out what went wrong, written to a file next to the build.
// Kept out of Documents on purpose: macOS asks for permission before an app touches that folder.
let dbgPath = NSHomeDirectory() + "/Library/Logs/fathomed-portal-spike.log"
func dbg(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let h = FileHandle(forWritingAtPath: dbgPath) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(toFile: dbgPath, atomically: true, encoding: .utf8) }
}

// ── what a session is ──
/// When each working session started working. Claude Code does not record this (its own timestamp moves on every
/// step of the work), so the app notes the moment it first sees a session go from not working to working.
enum Busy {
    static var since: [String: Double] = [:]
    static var primed = false
    static func note(_ sessions: [Session]) {
        let now = Date().timeIntervalSince1970
        for s in sessions where s.status == "busy" && since[s.id] == nil {
            // Already working when the app started: the true start is unknown, so count from its last recorded step.
            since[s.id] = primed ? now : s.updatedAt / 1000
        }
        let busy = Set(sessions.filter { $0.status == "busy" }.map { $0.id })
        for (k, v) in since where !busy.contains(k) { dbg("busy ended \(k.prefix(6)) after \(Int(now - v))s, status \(sessions.first { $0.id == k }?.status ?? "gone")") }
        since = since.filter { busy.contains($0.key) }
        primed = true
    }
}

struct Session: Identifiable, Equatable {
    let id: String
    let pid: Int32
    let cwd: String
    let status: String
    let updatedAt: Double
    var startedAt: Double = 0
    var tool = "claude"   // "claude" or "codex"
    var title: String
    var waitingFor: String? = nil
    var recap: String? = nil      // where the session is: Claude Code's own saved recap
    var lastAsked: String? = nil  // the most recent thing you typed in it
    /// One line saying where the session is, for places with room for only one.
    var gist: String? { recap ?? lastAsked.map { "Last asked: " + $0 } }
    var branch: String? = nil
    /// Opened but never used: Claude Code has no title or history for it, only a placeholder name like "repo-e9".
    var empty = false
    var project: String { (cwd as NSString).lastPathComponent }
    /// What to type in a terminal to bring this session back after it has been closed.
    var resumeCommand: String { tool == "codex" ? "codex resume \(id.replacingOccurrences(of: "codex-", with: ""))" : "claude --resume \(id)" }
    /// Stopped working in the last ten minutes, and you haven't been to it since it stopped
    /// (opened it from the panel, or had its terminal in front, which the editor helper reports).
    var finished: Bool { status == "idle" && seconds < 600 && (Seen.at[id] ?? 0) < updatedAt }
    /// needs you, finished, working, idle: in that order of urgency.
    var rank: Int { empty ? 4 : status == "waiting" ? 0 : finished ? 1 : status == "busy" ? 2 : 3 }
    var statusText: String {
        switch rank {
        case 0: return "needs you" + (waitingFor.map { " · \($0)" } ?? "")
        case 1: return "finished"
        case 2: return "working"
        case 3: return status == "closed" ? "closed" : "idle"
        default: return waitingFor != nil ? "sitting on a start-up dialog" : "opened, never used"
        }
    }
    var seconds: Double { max(0, Date().timeIntervalSince1970 - updatedAt / 1000) }
    /// Worth showing in the resting pill: working right now, or started waiting on you within the last hour.
    var active: Bool { status == "busy" || (status == "waiting" && seconds < 3600) }
    /// How long ago it last did something; for a session that is working, how long it has been working.
    var age: String {
        var s = seconds
        if status == "busy", let since = Busy.since[id] {
            s = max(0, Date().timeIntervalSince1970 - since)
            // A working session counts from the first second, so it never just says "now".
            if s < 60 { return "\(Int(s))s" }
            if s < 3600 { return "\(Int(s / 60))m \(Int(s) % 60)s" }
        }
        if s < 90 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
    var color: Color {
        status == "waiting" ? Color(red: 0.65, green: 0.62, blue: 0.94) : status == "busy" ? .white : Color(white: 0.38)
    }
}

/// Sessions you have opened from the panel, so "finished" clears once you've been to look.
enum Seen { static var at: [String: Double] = [:] }   // session id → when you were last in it, in milliseconds

// ── reading Claude Code's own files (read-only) ──
enum Loader {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var titleCache: [String: (size: UInt64, title: String?)] = [:]

    static func load() -> [Session] {
        let dir = home.appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [Session] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = o["pid"] as? Int, kill(Int32(pid), 0) == 0,
                  let sid = o["sessionId"] as? String else { continue }
            let cwd = o["cwd"] as? String ?? ""
            let updated = (o["statusUpdatedAt"] as? Double) ?? (o["updatedAt"] as? Double) ?? 0
            let found = title(for: sid, cwd: cwd)
            var s = Session(id: sid, pid: Int32(pid), cwd: cwd, status: o["status"] as? String ?? "idle", updatedAt: updated, title: found ?? "New session")
            s.empty = found == nil
            s.waitingFor = o["waitingFor"] as? String
            s.startedAt = o["startedAt"] as? Double ?? 0
            let ex = extras(for: sid, cwd: cwd); s.recap = ex.recap; s.branch = ex.branch; s.lastAsked = ex.asked
            out.append(s)
        }
        out += Codex.load()
        Busy.note(out)
        // Most recent activity first, and nothing else: a session only moves when something happens in it.
        return out.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }

    /// Sessions that are not open any more but whose conversations are still on disk, newest first.
    /// These are what you reopen after a restart. Looked up at most every 20 seconds.
    static var recentCache: (at: Double, list: [Session]) = (0, [])
    static func recent(excluding live: Set<String>) -> [Session] {
        let now = Date().timeIntervalSince1970
        if now - recentCache.at < 20 { return recentCache.list.filter { !live.contains($0.id) } }
        let root = home.appendingPathComponent(".claude/projects")
        var files: [(url: URL, at: Double)] = []
        for dir in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                guard f.pathExtension == "jsonl", UUID(uuidString: f.deletingPathExtension().lastPathComponent) != nil,
                      let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
                let t = d.timeIntervalSince1970
                if now - t < Double(max(1, Prefs.int("recentDays"))) * 86_400 { files.append((f, t)) }
            }
        }
        var out: [Session] = [], seen = Set<String>()
        for f in files.sorted(by: { $0.at > $1.at }).prefix(60) {
            let sid = f.url.deletingPathExtension().lastPathComponent
            guard let cwd = cwd(of: f.url), FileManager.default.fileExists(atPath: cwd), let name = title(for: sid, cwd: cwd) else { continue }
            // A conversation that was resumed can be saved under more than one id: show the newest only.
            guard seen.insert(cwd + "\n" + name).inserted else { continue }
            var s = Session(id: sid, pid: 0, cwd: cwd, status: "closed", updatedAt: f.at * 1000, title: name)
            let ex = extras(for: sid, cwd: cwd); s.recap = ex.recap; s.branch = ex.branch; s.lastAsked = ex.asked
            out.append(s)
            if out.count >= 30 { break }
        }
        recentCache = (now, out)
        return out.filter { !live.contains($0.id) }
    }
    /// The folder a saved conversation was running in, read from the start of its history.
    static var cwdCache: [String: String] = [:]
    static func cwd(of url: URL) -> String? {
        if let c = cwdCache[url.path] { return c }
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = h.readData(ofLength: 400_000)
        guard let r = head.range(of: Data("\"cwd\":\"".utf8)), let q = head[r.upperBound...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        let c = String(decoding: head[r.upperBound..<q], as: UTF8.self)
        cwdCache[url.path] = c
        return c
    }

    /// The newest title Claude Code wrote into this session's history, found by searching the file from the end.
    static func title(for sid: String, cwd: String) -> String? {
        let esc = cwd.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        let url = home.appendingPathComponent(".claude/projects/\(esc)/\(sid).jsonl")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? UInt64 else { return nil }
        if let c = titleCache[sid], c.size == size { return c.title }
        var t: String? = titleCache[sid]?.title
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           let r = data.range(of: Data("\"type\":\"ai-title\"".utf8), options: .backwards) {
            let nl = UInt8(ascii: "\n")
            let start = data[..<r.lowerBound].lastIndex(of: nl).map { $0 + 1 } ?? data.startIndex
            let end = data[r.upperBound...].firstIndex(of: nl) ?? data.endIndex
            if let o = try? JSONSerialization.jsonObject(with: data[start..<end]) as? [String: Any], let s = o["aiTitle"] as? String { t = s }
        }
        // No title yet (Claude Code writes one a little after the first message): use the first thing that was asked.
        if t == nil { t = firstPrompt(url) ?? "Untitled session" }
        titleCache[sid] = (size, t)
        return t
    }

    /// Where a session is and which git branch it is on, read from the end of its history file.
    static var extraCache: [String: (size: UInt64, recap: String?, branch: String?, asked: String?)] = [:]
    static func extras(for sid: String, cwd: String) -> (recap: String?, branch: String?, asked: String?) {
        let esc = cwd.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        let url = home.appendingPathComponent(".claude/projects/\(esc)/\(sid).jsonl")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? UInt64 else { return (nil, nil, nil) }
        if let c = extraCache[sid], c.size == size { return (c.recap, c.branch, c.asked) }
        var recap: String? = nil, branch: String? = nil, asked: String? = nil
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            // Claude Code writes a short recap into the history when a session has been left for a few minutes.
            if let hit = lastLine(in: data, containing: "\"subtype\":\"away_summary\"") { recap = hit.obj["content"] as? String }
            if let r = data.range(of: Data("\"gitBranch\":\"".utf8), options: .backwards), let q = data[r.upperBound...].firstIndex(of: UInt8(ascii: "\"")) {
                branch = String(decoding: data[r.upperBound..<q], as: UTF8.self)
            }
            asked = lastPrompt(in: data)
        }
        extraCache[sid] = (size, recap, branch, asked)
        return (recap, branch, asked)
    }
    /// The last line of the file that contains some text, parsed, searching backwards from the end (or from an earlier point).
    static func lastLine(in data: Data, containing needle: String, before: Data.Index? = nil) -> (obj: [String: Any], start: Data.Index)? {
        let hay = before.map { data[..<$0] } ?? data
        guard let r = hay.range(of: Data(needle.utf8), options: .backwards) else { return nil }
        let nl = UInt8(ascii: "\n")
        let start = data[..<r.lowerBound].lastIndex(of: nl).map { $0 + 1 } ?? data.startIndex
        let end = data[r.upperBound...].firstIndex(of: nl) ?? data.endIndex
        guard let o = try? JSONSerialization.jsonObject(with: data[start..<end]) as? [String: Any] else { return ([:], start) }
        return (o, start)
    }
    /// The most recent thing the person typed, skipping tool output and system notes.
    static func lastPrompt(in data: Data) -> String? {
        var before: Data.Index? = nil
        for _ in 0..<40 {
            guard let hit = lastLine(in: data, containing: "\"type\":\"user\"", before: before) else { return nil }
            before = hit.start
            let o = hit.obj
            guard o["isMeta"] as? Bool != true, let m = o["message"] as? [String: Any] else { continue }
            var text: String? = m["content"] as? String
            if text == nil, let parts = m["content"] as? [[String: Any]] { text = parts.first { $0["type"] as? String == "text" }?["text"] as? String }
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("["), !t.hasPrefix("This session is being continued from a previous conversation") else { continue }
            let one = t.split(separator: "\n").first.map(String.init) ?? t
            return one.count > 400 ? String(one.prefix(399)) + "…" : one
        }
        return nil
    }

    /// The first thing typed in a session, from the start of its history file.
    static func firstPrompt(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = String(decoding: h.readData(ofLength: 400_000), as: UTF8.self)
        for line in head.split(separator: "\n") where line.contains("\"type\":\"user\"") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], o["isMeta"] as? Bool != true,
                  let m = o["message"] as? [String: Any] else { continue }
            var text: String? = m["content"] as? String
            if text == nil, let parts = m["content"] as? [[String: Any]] { text = parts.first { $0["type"] as? String == "text" }?["text"] as? String }
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") else { continue }
            let one = t.split(separator: "\n").first.map(String.init) ?? t
            return one.count > 70 ? String(one.prefix(69)) + "…" : one
        }
        return nil
    }

    /// Walks up from a session's process: the app that owns its terminal, and every process on the way there
    /// (one of which is the shell that the terminal tab is running).
    static var ownerCache: [Int32: (app: String?, chain: [Int32])] = [:]
    static func owner(of pid: Int32) -> (app: String?, chain: [Int32]) {
        if let c = ownerCache[pid] { return c }
        let r = walk(from: pid); ownerCache[pid] = r; return r
    }
    /// The session whose terminal the editor helper last reported as the one in front, if the helper is installed.
    static func currentSession(among sessions: [Session]) -> String? {
        let url = home.appendingPathComponent(".fathomed/active-terminal.json")
        guard let data = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let pid = o["pid"] as? Int else { return nil }
        return sessions.first { owner(of: $0.pid).chain.contains(Int32(pid)) }?.id
    }
    private static func walk(from pid: Int32) -> (app: String?, chain: [Int32]) {
        var p = pid, chain: [Int32] = []
        for _ in 0..<14 {
            chain.append(p)
            let proc = Process(); proc.executableURL = URL(fileURLWithPath: "/bin/ps"); proc.arguments = ["-o", "ppid=,comm=", "-p", "\(p)"]
            let pipe = Pipe(); proc.standardOutput = pipe
            guard (try? proc.run()) != nil else { return (nil, chain) }
            proc.waitUntilExit()
            let line = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sp = line.firstIndex(of: " "), let ppid = Int32(line[..<sp]) else { return (nil, chain) }
            let comm = String(line[sp...]).trimmingCharacters(in: .whitespaces)
            if let r = comm.range(of: ".app/") { return (String(comm[..<r.lowerBound]) + ".app", chain) }
            if ppid <= 1 { return (nil, chain) }
            p = ppid
        }
        return (nil, chain)
    }
}

// ── reading Codex's own files (read-only) ──
// Codex has no list of open sessions, so: find running codex processes, see which session log each has open,
// and look that session up in Codex's local database for its name, folder and branch.
enum Codex {
    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
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
            guard let log = open.log ?? logOf[pid] else {
                // Running, but nothing has been asked yet, so there is no log to name it by.
                guard let cwd = open.cwd, FileManager.default.fileExists(atPath: cwd), cwd != "/" else { continue }
                var s = Session(id: "codex-pid-\(pid)", pid: pid, cwd: cwd, status: "idle", updatedAt: Date().timeIntervalSince1970 * 1000, title: "New session")
                s.tool = "codex"; s.empty = true; out.append(s); continue
            }
            logOf[pid] = log
            let id = String(((log as NSString).lastPathComponent as NSString).deletingPathExtension.suffix(36))
            guard !seen.contains(id) else { continue }; seen.insert(id)
            var title = "Untitled session", cwd = open.cwd ?? "", branch: String? = nil, recap: String? = nil
            if let db, let row = thread(db, id) {
                title = row.title; if !row.cwd.isEmpty { cwd = row.cwd }; branch = row.branch
                if let p = row.preview, !p.isEmpty { recap = p } else if let f = row.first, !f.isEmpty { recap = "First asked: " + f }
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: log)
            let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
            var s = Session(id: "codex-" + id, pid: pid, cwd: cwd, status: working(log) ? "busy" : "idle", updatedAt: modified * 1000, title: title)
            s.tool = "codex"; s.branch = branch; s.recap = recap
            out.append(s)
        }
        return out
    }

    /// Process numbers of running Codex programs.
    static func running() -> [Int32] {
        let lines = shell("/bin/ps", ["-axo", "pid=,comm="]).split(separator: "\n")
        return lines.compactMap { line -> Int32? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]) else { return nil }
            let name = (String(t[sp...]).trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
            return name == "codex" || name.hasPrefix("codex-") ? pid : nil
        }
    }
    /// The session log a Codex process has open, and the folder it is running in.
    static func files(of pid: Int32) -> (log: String?, cwd: String?) {
        var log: String? = nil, cwd: String? = nil, fd = ""
        for line in shell("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-Fn"]).split(separator: "\n") {
            if line.hasPrefix("f") { fd = String(line.dropFirst()) }
            else if line.hasPrefix("n") {
                let name = String(line.dropFirst())
                if fd == "cwd" { cwd = name }
                if name.contains("/.codex/sessions/") && name.hasSuffix(".jsonl") { log = name }
            }
        }
        return (log, cwd)
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

// ── state the interface draws from ──
final class Model: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var open = false
    @Published var selected = 0
    @Published var query = ""
    /// The session just closed from here, shown briefly so a slip can be undone by resuming it.
    @Published var closed: (title: String, command: String)? = nil
    /// Closed sessions that can be reopened, newest first.
    @Published var recent: [Session] = []
    var recentHits: [Session] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return words.isEmpty ? recent : recent.filter { s in let hay = (s.title + " " + s.project + " " + (s.branch ?? "")).lowercased(); return words.allSatisfy { hay.contains($0) } }
    }
    @Published var currentId: String?   // the session you are in, when the editor helper can tell us
    @Published var notchWidth: CGFloat = 0
    @Published var barHeight: CGFloat = 26
    /// Sessions you have pinned, remembered between launches.
    @Published var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pinned") ?? [])
    func togglePin(_ id: String) {
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        UserDefaults.standard.set(Array(pinned), forKey: "pinned")
    }

    /// Sessions matching the search, most recent activity first, not grouped.
    var hits: [Session] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return words.isEmpty ? sessions : sessions.filter { s in let hay = (s.title + " " + s.project + " " + (s.branch ?? "")).lowercased(); return words.allSatisfy { hay.contains($0) } }
    }
    var filtered: [Session] {
        let q = query.lowercased()
        // Every word typed or spoken has to appear somewhere in the title or the repo name.
        let words = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let hits = words.isEmpty ? sessions : sessions.filter { s in let hay = (s.title + " " + s.project).lowercased(); return words.allSatisfy { hay.contains($0) } }
        // Grouped by repo: the repo with the most recent activity comes first.
        var order: [String] = []
        for s in hits where !order.contains(s.project) { order.append(s.project) }
        // Within a repo: most recent activity first, with never-used sessions last. State is shown by the orb, not by position.
        return order.flatMap { name in hits.filter { $0.project == name && !$0.empty } + hits.filter { $0.project == name && $0.empty } }
    }
    var active: [Session] { sessions.filter { $0.active } }
    /// True when both Claude Code and Codex sessions are open; only then is each row marked with which it is.
    var mixed: Bool { Set(sessions.map(\.tool)).count > 1 }
    var spotlight: Session? { sessions.filter { $0.rank < 3 }.min { ($0.rank, -$0.updatedAt) < ($1.rank, -$1.updatedAt) } }
    /// In words, so nothing on the panel is a bare number: "1 working · 1 needs you · 16 open".
    var summary: String {
        let w = sessions.filter { $0.rank == 2 }.count, n = sessions.filter { $0.rank == 0 }.count, f = sessions.filter { $0.rank == 1 }.count
        return [n > 0 ? "\(n) need\(n == 1 ? "s" : "") you" : nil, f > 0 ? "\(f) finished" : nil, w > 0 ? "\(w) working" : nil, "\(sessions.count) open"].compactMap { $0 }.joined(separator: " · ")
    }
    var sideWidth: CGFloat { 40 }
    var pillWidth: CGFloat { notchWidth > 0 ? notchWidth + sideWidth * 2 : 56 }
}

/// Ends a session the way closing its terminal tab would: the agent is asked to quit, then the shell it was
/// started from is hung up, which makes the terminal (in any editor or terminal app) close the tab itself.
/// Nothing is deleted: the conversation stays on disk and can be resumed.
enum Closer {
    static func info(_ pid: Int32) -> (ppid: Int32, comm: String)? {
        let proc = Process(); proc.executableURL = URL(fileURLWithPath: "/bin/ps"); proc.arguments = ["-o", "ppid=,comm=", "-p", "\(pid)"]
        let pipe = Pipe(); proc.standardOutput = pipe
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let line = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sp = line.firstIndex(of: " "), let ppid = Int32(line[..<sp]) else { return nil }
        return (ppid, String(line[sp...]).trimmingCharacters(in: .whitespaces))
    }
    static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }
    static func close(_ pid: Int32) {
        guard pid > 1, let me = info(pid) else { return }
        // Only a shell directly above the agent is hung up; anything else (an editor, a script) is left alone.
        var shell: Int32? = nil
        if me.ppid > 1, let parent = info(me.ppid) {
            let name = (parent.comm as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if ["zsh", "bash", "fish", "sh", "nu"].contains(name) { shell = me.ppid }
        }
        dbg("close: pid \(pid) (\(me.comm)), shell \(shell.map(String.init) ?? "none")")
        kill(pid, SIGTERM)
        for _ in 0..<15 where alive(pid) { Thread.sleep(forTimeInterval: 0.1) }
        if let shell, alive(shell) { kill(shell, SIGHUP) }
        for _ in 0..<15 where alive(pid) { Thread.sleep(forTimeInterval: 0.1) }
        if alive(pid) { kill(pid, SIGKILL) }
        dbg("close: agent alive \(alive(pid)), shell alive \(shell.map(alive) ?? false)")
    }
}

/// Every choice in the settings window, with its default. Read straight from here wherever it matters.
enum Prefs {
    static let defaults: [String: Any] = [
        "openOnHover": true, "hotkey": "opt-space", "showLastMessage": true, "showRecent": true, "recentDays": 14,
        "showMic": true, "widgetOnTop": true, "confirmClose": true, "reopenIn": "auto", "demoMode": false, "hiddenRepos": "",
    ]
    static func register() { UserDefaults.standard.register(defaults: defaults) }
    static func bool(_ k: String) -> Bool { UserDefaults.standard.bool(forKey: k) }
    static func string(_ k: String) -> String { UserDefaults.standard.string(forKey: k) ?? "" }
    static func int(_ k: String) -> Int { UserDefaults.standard.integer(forKey: k) }
    /// Repo names that are never shown, lower-cased. Typed in settings separated by commas.
    static var hiddenRepos: Set<String> {
        Set(string("hiddenRepos").lowercased().split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
    /// The shortcuts on offer: a label, the key and the modifier keys.
    static let hotkeys: [(id: String, label: String, key: Int, mods: Int)] = [
        ("opt-space", "⌥ Space", kVK_Space, optionKey), ("ctrl-space", "⌃ Space", kVK_Space, controlKey),
        ("opt-shift-space", "⌥ ⇧ Space", kVK_Space, optionKey | shiftKey), ("cmd-shift-space", "⌘ ⇧ Space", kVK_Space, cmdKey | shiftKey),
        ("ctrl-opt-space", "⌃ ⌥ Space", kVK_Space, controlKey | optionKey), ("none", "None", 0, 0),
    ]
    static let editors: [(id: String, label: String, app: String, scheme: String)] = [
        ("cursor", "Cursor", "/Applications/Cursor.app", "cursor"), ("vscode", "VS Code", "/Applications/Visual Studio Code.app", "vscode"),
        ("windsurf", "Windsurf", "/Applications/Windsurf.app", "windsurf"), ("vscodium", "VSCodium", "/Applications/VSCodium.app", "vscodium"),
    ]
}

/// Made-up sessions shown in place of your own, for demos and screen recordings. Nothing here is read from disk,
/// and clicking a sample session does not open or close anything.
enum Demo {
    static var on: Bool { Prefs.bool("demoMode") }
    static var hidden = Set<String>()
    //                 id, repo, title, status, seconds ago, branch, last message, recap, waiting for
    static let rows: [(String, String, String, String, Double, String, String, String, String?)] = [
        ("d1", "storefront", "Checkout fails for saved cards", "waiting", 40, "fix/saved-card-checkout", "go ahead and run the migration", "Found the cause: the saved-card token is read before it is refreshed. The fix is written and tested; it needs your OK to run the database migration.", "permission"),
        ("d2", "storefront", "Speed up the product search page", "busy", 134, "perf/search-page", "try caching the facet counts", "Measuring the search page. The facet counts are the slow part; trying a cache for them now.", nil),
        ("d3", "storefront", "Holiday banner and countdown", "idle", 190, "feature/holiday-banner", "looks good, make the countdown end at midnight local time", "The banner and countdown are done and match the design. Next: you review it on a phone-sized screen.", nil),
        ("d4", "ios-app", "Push notifications arrive twice", "busy", 61, "bugfix/duplicate-push", "check whether both the old and new token are registered", "Reproduced the duplicate. Checking whether the device is registered under two tokens.", nil),
        ("d5", "ios-app", "Onboarding screens redesign", "idle", 3_100, "feature/onboarding-v2", "use the larger illustration on the second screen", "Three of the four screens are rebuilt. The last one is waiting on the final copy.", nil),
        ("d6", "api-server", "Rate limit the export endpoint", "idle", 9_400, "feature/export-rate-limit", "100 a minute per account is fine", "Rate limiting is in and covered by tests. Next: decide the limit for enterprise accounts.", nil),
        ("d7", "api-server", "Upgrade to the new Postgres driver", "idle", 97_000, "chore/pg-driver", "hold off until after the release", "Paused. The upgrade works locally; two integration tests still fail on connection pooling.", nil),
        ("d8", "docs-site", "Rewrite the getting-started guide", "idle", 20_000, "docs/getting-started", "shorter, and lead with the install command", "First draft is written. Next: you read it through for tone.", nil),
    ]
    static let closedRows: [(String, String, String, Double, String, String)] = [
        ("c1", "storefront", "Fix the cart badge count", 5_200, "fix/cart-badge", "ship it"),
        ("c2", "api-server", "Webhook retries with backoff", 30_000, "feature/webhook-retries", "add a test for the fifth retry"),
        ("c3", "ios-app", "Dark mode for settings", 180_000, "feature/settings-dark-mode", "the toggles are too dim"),
        ("c4", "docs-site", "Broken links in the API reference", 260_000, "fix/api-ref-links", "run the link checker again"),
    ]
    static func sessions() -> [Session] {
        let now = Date().timeIntervalSince1970
        return rows.filter { !hidden.contains($0.0) }.map { r in
            var s = Session(id: r.0, pid: 0, cwd: "/Projects/" + r.1, status: r.3, updatedAt: (now - r.4) * 1000, title: r.2)
            s.branch = r.5; s.lastAsked = r.6; s.recap = r.7; s.waitingFor = r.8
            if r.3 == "busy" { Busy.since[r.0] = Busy.since[r.0] ?? now - r.4 }
            return s
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    static func closed() -> [Session] {
        let now = Date().timeIntervalSince1970
        return closedRows.map { r in
            var s = Session(id: r.0, pid: 0, cwd: "/Projects/" + r.1, status: "closed", updatedAt: (now - r.3) * 1000, title: r.2)
            s.branch = r.4; s.lastAsked = r.5
            return s
        }
    }
}

struct SettingsView: View {
    weak var app: AppDelegate?
    @AppStorage("openOnHover") var openOnHover = true
    @AppStorage("hotkey") var hotkey = "opt-space"
    @AppStorage("showLastMessage") var showLastMessage = true
    @AppStorage("showRecent") var showRecent = true
    @AppStorage("recentDays") var recentDays = 14
    @AppStorage("showMic") var showMic = true
    @AppStorage("widgetOnTop") var widgetOnTop = true
    @AppStorage("confirmClose") var confirmClose = true
    @AppStorage("reopenIn") var reopenIn = "auto"
    @AppStorage("demoMode") var demoMode = false
    @AppStorage("hiddenRepos") var hiddenRepos = ""
    var body: some View {
        Form {
            Section("Opening the panel") {
                Toggle("Open when the pointer is pushed into the notch", isOn: $openOnHover)
                Picker("Keyboard shortcut", selection: $hotkey) { ForEach(Prefs.hotkeys, id: \.id) { Text($0.label).tag($0.id) } }
            }
            Section("What each session shows") {
                Toggle("Your last message", isOn: $showLastMessage)
                Toggle("Microphone button in search", isOn: $showMic)
            }
            Section("Closed sessions") {
                Toggle("List recently closed sessions so they can be reopened", isOn: $showRecent)
                Picker("Go back", selection: $recentDays) {
                    Text("1 day").tag(1); Text("3 days").tag(3); Text("7 days").tag(7); Text("14 days").tag(14); Text("30 days").tag(30)
                }.disabled(!showRecent)
                Picker("Reopen them in", selection: $reopenIn) {
                    Text("The editor I last used").tag("auto")
                    ForEach(Prefs.editors.filter { FileManager.default.fileExists(atPath: $0.app) }, id: \.id) { Text($0.label).tag($0.id) }
                }.disabled(!showRecent)
                Toggle("Ask before closing a session that is working or waiting on you", isOn: $confirmClose)
            }
            Section("Stay-on-screen window") {
                Toggle("Keep it above other windows", isOn: $widgetOnTop)
            }
            Section {
                TextField("Never show these repos", text: $hiddenRepos, prompt: Text("client-site, internal-tools"))
            } header: { Text("Privacy") } footer: {
                Text("Repo folder names, separated by commas. Their sessions are left out everywhere, open or closed.")
            }
            Section {
                Toggle("Show sample sessions instead of mine", isOn: $demoMode)
            } header: { Text("Demo") } footer: {
                Text("For demos and screen recordings. Your real repos, branches and messages are hidden, and clicking a sample session does nothing.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: hotkey) { _, _ in app?.registerHotKey() }
        .onChange(of: widgetOnTop) { _, on in app?.widget?.level = on ? .floating : .normal }
        .onChange(of: recentDays) { _, _ in Loader.recentCache.at = 0; app?.refresh() }
        .onChange(of: showRecent) { _, _ in app?.refresh() }
        .onChange(of: demoMode) { _, _ in Demo.hidden = []; app?.refresh() }
        .onChange(of: hiddenRepos) { _, _ in app?.refresh() }
    }
}

// ── the interface ──
struct RootView: View {
    @ObservedObject var model: Model
    @ObservedObject var dictation: Dictation
    weak var app: AppDelegate?
    var detached = false   // true for the stay-on-screen window, false for the panel under the notch
    @FocusState private var searchFocused: Bool
    @State private var hovered: String?
    @AppStorage("showLastMessage") private var showLast = true
    @AppStorage("showMic") private var showMic = true
    @AppStorage("confirmClose") private var confirmBusy = true
    @State private var overX: String?                 // the row whose x the pointer is on
    static let showX = CommandLine.arguments.contains("--show-x")   // for screenshots: show every row's x
    @State private var confirmClose: String?          // the row whose x has been clicked once and is asking "Close?"
    @State private var showUnused: Set<String> = []   // groups whose never-used sessions are expanded
    @State private var collapsed: Set<String> = []    // groups folded shut
    @State private var detailId: String?              // the session shown in the detail pane: the last one pointed at
    @AppStorage("widgetGroup") private var groupBy = "repo"    // repo | state
    @AppStorage("widgetFilter") private var filter = "all"     // all | active | pinned
    static let openWidth: CGFloat = 640, openHeight: CGFloat = 470

    // Closed, the black shape is exactly the notch (or nothing, on a screen without one), so it can't be seen.
    // Opening grows that shape outward and down while the contents fade in; closing runs it backwards.
    var body: some View { if detached { widgetBody } else { panelBody } }

    /// The stay-on-screen window. One aligned list, in the manner of an issue tracker: a slim header per group,
    /// one row per session with its facts in columns, and, when the window is wide, a pane on the right that
    /// shows everything about the session you are pointing at.
    var widgetBody: some View {
        GeometryReader { geo in
            let table = geo.size.width >= 620, wide = geo.size.width >= 1060
            let groups = sessionGroups()
            VStack(spacing: 0) {
                // Starts to the right of the window's close, minimise and full-screen buttons.
                HStack(spacing: 8) { dots; stats; Spacer() }.padding(.leading, 78).padding(.trailing, 16).frame(height: 30)
                searchRow
                toolbar
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(groups) { g in
                                Section(header: groupHeader(g)) {
                                    if !collapsed.contains(g.id) {
                                        ForEach(g.items) { s in sessionRow(s, table: table) }
                                        if !g.unused.isEmpty {
                                            if showUnused.contains(g.id) { ForEach(g.unused) { s in sessionRow(s, table: table) } }
                                            Text(showUnused.contains(g.id) ? "hide unused" : "\(g.unused.count) opened but never used")
                                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.3))
                                                .padding(.leading, 44).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                                                .contentShape(Rectangle()).modifier(PointerLink())
                                                .onTapGesture { toggle(&showUnused, g.id) }
                                        }
                                    }
                                }
                            }
                            if groups.isEmpty {
                                Text(model.query.isEmpty ? "Nothing here yet." : "No session matches that.")
                                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.4)).padding(24).frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.bottom, 14)
                        // When a session has activity it glides up to its new place, and the others slide to make room.
                        .animation(.spring(response: 0.5, dampingFraction: 0.84), value: groups.flatMap { $0.items.map { $0.id } })
                    }
                    if wide {
                        Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                        detailPane.frame(width: 380)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Dark enough that the list reads the same whatever is behind the window; the glass shows as a faint tint.
        .background(GlassBack(shape: Rectangle(), dim: 0.4, frosted: Color(white: 0.045).opacity(0.86), shade: 0.52).environment(\.colorScheme, .dark))
        .overlay(alignment: .bottom) { closedToast }
        .ignoresSafeArea()
    }

    func toggle(_ set: inout Set<String>, _ id: String) { if set.contains(id) { set.remove(id) } else { set.insert(id) } }
    func isActive(_ s: Session) -> Bool { !s.empty && (s.rank < 3 || s.seconds < 86_400) }

    static let closedGroup = "Recently closed · click to reopen"
    struct SessionGroup: Identifiable { let id: String; let items: [Session]; let unused: [Session] }
    /// The list's contents: search, then the chosen filter, then grouped by repo or by state.
    func sessionGroups() -> [SessionGroup] {
        var rows = model.hits
        if filter == "active" { rows = rows.filter(isActive) }
        if filter == "pinned" { rows = rows.filter { model.pinned.contains($0.id) } }
        if groupBy == "state" {
            let buckets: [(String, (Session) -> Bool)] = [
                ("Needs you", { $0.rank == 0 }), ("Finished", { $0.rank == 1 }), ("Working", { $0.rank == 2 }),
                ("Idle, used today", { $0.rank == 3 && $0.seconds < 86_400 }), ("Idle, older", { $0.rank == 3 && $0.seconds >= 86_400 }),
            ]
            var out = buckets.map { SessionGroup(id: $0.0, items: rows.filter($0.1), unused: []) }.filter { !$0.items.isEmpty }
            let unused = rows.filter { $0.empty }
            if !unused.isEmpty { out.append(SessionGroup(id: "Never used", items: [], unused: unused)) }
            if filter == "all", !model.recentHits.isEmpty { out.append(SessionGroup(id: Self.closedGroup, items: model.recentHits, unused: [])) }
            return out
        }
        var out = repos(in: rows).map { name in
            SessionGroup(id: name, items: rows.filter { $0.project == name && !$0.empty }, unused: rows.filter { $0.project == name && $0.empty })
        }
        if filter == "all", !model.recentHits.isEmpty { out.append(SessionGroup(id: Self.closedGroup, items: model.recentHits, unused: [])) }
        return out
    }

    var searchRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
            TextField("", text: $model.query, prompt: Text("Search sessions").foregroundStyle(.white.opacity(0.35)))
                .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(.white).tint(.white)
            if showMic {
                Image(systemName: dictation.listening ? "mic.fill" : "mic").font(.system(size: 13))
                    .foregroundStyle(dictation.listening ? PortalMark.lavender : .white.opacity(0.45))
                    .contentShape(Rectangle().inset(by: -6)).onTapGesture { dictation.toggle() }.help("Speak your search")
            }
            gear
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    /// Which sessions to show, and how to group them. Both choices are remembered.
    var toolbar: some View {
        HStack(spacing: 6) {
            chip("All", model.hits.count, on: filter == "all") { filter = "all" }
            chip("Active", model.hits.filter(isActive).count, on: filter == "active") { filter = "active" }
            chip("Pinned", model.hits.filter { model.pinned.contains($0.id) }.count, on: filter == "pinned") { filter = "pinned" }
            Spacer()
            Text("Group by").font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
            chip("Repo", nil, on: groupBy == "repo") { groupBy = "repo" }
            chip("State", nil, on: groupBy == "state") { groupBy = "state" }
        }
        .padding(.horizontal, 14).padding(.bottom, 9)
    }
    func chip(_ label: String, _ count: Int?, on: Bool, _ act: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.white.opacity(on ? 0.95 : 0.55))
            if let count { Text("\(count)").foregroundStyle(.white.opacity(on ? 0.5 : 0.28)).monospacedDigit() }
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(on ? 0.12 : 0)))
        .contentShape(Rectangle()).modifier(PointerLink())
        .onTapGesture(perform: act)
    }

    /// A slim bar naming the group, how many are in it and what they are doing. Click to fold it.
    func groupHeader(_ g: SessionGroup) -> some View {
        let all = g.items, doing = [all.filter { $0.rank == 0 }.count, all.filter { $0.rank == 1 }.count, all.filter { $0.rank == 2 }.count]
        let note = groupBy == "state" ? "" : zip(doing, ["needs you", "finished", "working"]).filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        return HStack(spacing: 8) {
            Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                .rotationEffect(.degrees(collapsed.contains(g.id) ? 0 : 90))
            if groupBy == "repo" && g.id != Self.closedGroup { RepoIcon().stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)).frame(width: 11, height: 11) }
            Text(g.id).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.82))
            Text("\(all.count)").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.32)).monospacedDigit()
            if !note.isEmpty { Text(note).font(.system(size: 11)).foregroundStyle(PortalMark.lavender.opacity(0.9)) }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Color(white: 0.105))
        .contentShape(Rectangle()).modifier(PointerLink())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { toggle(&collapsed, g.id) } }
    }

    @ViewBuilder func orb(_ s: Session) -> some View {
        if s.rank == 2 { Orb() }
        else if s.rank == 0 { Orb(spinning: false) }
        else if s.rank == 1 { Orb(spinning: false, tint: Color(white: 0.85), glow: 0.5) }
        else { Orb(spinning: false, tint: Color(white: 0.55), size: 8, glow: 0).opacity(0.55) }
    }
    func stateWord(_ s: Session) -> String { s.status == "closed" ? "closed" : ["needs you", "finished", "working", "idle", "unused"][s.rank] }
    func stateColor(_ s: Session) -> Color { s.rank == 0 ? PortalMark.lavender : s.rank < 3 ? .white.opacity(0.9) : .white.opacity(0.34) }

    /// A repo name with the small repository mark in front.
    func repoText(_ name: String, tone: Double = 0.45) -> Text {
        name.isEmpty ? Text("") : Text(Image(nsImage: RepoGlyph.image(tone))).baselineOffset(-1.5) + Text(" " + name)
    }
    /// A branch name with the small git-branch mark in front, so it reads as a branch and not as a folder.
    func branchText(_ b: String?, lead: String = "", tone: Double = 0.45) -> Text {
        guard let b else { return Text("") }
        return Text(lead) + Text(Image(nsImage: BranchIcon.image(tone))).baselineOffset(-1.5) + Text(" " + b)
    }

    /// One session on one line, its facts in columns that line up down the whole list.
    func sessionRow(_ s: Session, table: Bool) -> some View {
        let old = s.rank >= 3 && s.seconds >= 86_400   // idle since yesterday or earlier: shown quieter
        let repo = groupBy == "state" || s.status == "closed" ? s.project : ""
        let place = repoText(repo, tone: old ? 0.26 : 0.42) + branchText(s.branch, lead: repo.isEmpty ? "" : "  ", tone: old ? 0.26 : 0.42)
        return HStack(spacing: 12) {
            orb(s).frame(width: 14, height: 14)
            if table {
                Text(s.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(old ? 0.62 : 0.96))
                    .lineLimit(1).frame(width: 270, alignment: .leading)
                // The last thing you typed there; the recap if nothing has been typed.
                Text((showLast ? s.lastAsked : nil) ?? s.recap ?? "").font(.system(size: 12)).foregroundStyle(.white.opacity(old ? 0.28 : 0.5))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                place.font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(old ? 0.26 : 0.42))
                    .lineLimit(1).truncationMode(.middle).frame(width: groupBy == "state" ? 230 : 170, alignment: .leading)
                Text(stateWord(s)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(stateColor(s)).frame(width: 70, alignment: .leading)
                Text(s.age).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.white.opacity(0.38)).frame(width: 52, alignment: .trailing)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(old ? 0.62 : 0.96)).lineLimit(1)
                    (Text(stateWord(s)).foregroundColor(stateColor(s)) + (Text("  \(s.age)" + (repo.isEmpty ? "" : "  ·  ")) + repoText(repo, tone: 0.4) + branchText(s.branch, lead: "  ·  ", tone: 0.4)).foregroundColor(.white.opacity(0.4)))
                        .font(.system(size: 11)).lineLimit(1)
                    if showLast, let asked = s.lastAsked {
                        Text(asked).font(.system(size: 11.5)).foregroundStyle(.white.opacity(old ? 0.3 : 0.62)).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            closeControl(s)
            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(model.pinned.contains(s.id) ? 0.4 : 0)).frame(width: 10)
        }
        .padding(.horizontal, 16).padding(.vertical, table ? 7.5 : 6.5)
        // The session whose terminal is in front is highlighted, the same way as in the notch panel.
        // The session whose terminal is in front is highlighted, the same way as in the notch panel.
        .background(Color.white.opacity(s.id == model.currentId ? 0.11 : hovered == s.id ? 0.07 : detailId == s.id ? 0.04 : 0))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = s.id; detailId = s.id; NSCursor.pointingHand.set() } else if hovered == s.id { hovered = nil; confirmClose = nil; NSCursor.arrow.set() }
        }
        .modifier(PointerLink())
        .onTapGesture { app?.go(s) }
        .contextMenu { rowMenu(s) }
    }

    @ViewBuilder func rowMenu(_ s: Session) -> some View {
        Button(model.pinned.contains(s.id) ? "Unpin" : "Pin") { model.togglePin(s.id) }
        if !s.empty { Button("Copy resume command") { copyResume(s) } }
        Button("Show folder in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.cwd) }
    }
    func copyResume(_ s: Session) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.resumeCommand, forType: .string)
    }

    var gear: some View {
        Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
            .contentShape(Rectangle().inset(by: -6)).modifier(PointerLink())
            .onTapGesture { app?.showSettings() }.help("Settings")
    }
    /// The x on a row. A session that is working or waiting on you asks once more before it closes.
    @ViewBuilder func closeControl(_ s: Session) -> some View {
        if confirmClose == s.id {
            Text("Close?").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color(red: 1, green: 0.5, blue: 0.47))
                .padding(.horizontal, 7).padding(.vertical, 2.5).background(Capsule().fill(Color(red: 1, green: 0.35, blue: 0.3).opacity(0.18)))
                .contentShape(Rectangle()).modifier(PointerLink())
                .onTapGesture { confirmClose = nil; app?.end(s) }
        } else if (hovered == s.id || Self.showX) && s.status != "closed" {
            // A bare x, as on a Mac tab: it only gets a backing when the pointer is on the x itself.
            Image(systemName: "xmark").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(overX == s.id ? 0.95 : 0.5))
                .frame(width: 18, height: 18).background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(overX == s.id ? 0.14 : 0)))
                .contentShape(Rectangle()).modifier(PointerLink()).help("Close this session")
                .onHover { overX = $0 ? s.id : (overX == s.id ? nil : overX) }
                .onTapGesture { if confirmBusy && (s.rank == 0 || s.rank == 2) { confirmClose = s.id } else { app?.end(s) } }
        }
    }
    /// Shown for a few seconds after a close.
    @ViewBuilder var closedToast: some View {
        if let c = model.closed {
            HStack(spacing: 10) {
                Text("Closed \"\(c.title)\"").foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                Text("Copy resume command").foregroundStyle(PortalMark.lavender).fixedSize().contentShape(Rectangle()).modifier(PointerLink())
                    .onTapGesture { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.command, forType: .string); model.closed = nil }
            }
            .font(.system(size: 11.5, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 8)
            .background(Capsule().fill(Color(white: 0.16)).overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5)))
            .padding(.bottom, 12).padding(.horizontal, 12)
            .transition(.opacity)
        }
    }

    /// Everything about one session: the one you last pointed at, or failing that the one that most wants you.
    @ViewBuilder var detailPane: some View {
        if let s = model.sessions.first(where: { $0.id == detailId }) ?? model.spotlight ?? model.sessions.first(where: { !$0.empty }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        orb(s).frame(width: 14, height: 14)
                        Text(stateWord(s)).font(.system(size: 12, weight: .medium)).foregroundStyle(stateColor(s))
                        Text(s.age == "now" ? "now" : "for \(s.age)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                        Spacer()
                    }
                    Text(s.title).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white.opacity(0.97))
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                    (repoText(s.project) + branchText(s.branch, lead: "  ·  ")).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45)).padding(.top, 5)
                    if let recap = s.recap { detailBlock("Where it is", recap) }
                    if let asked = s.lastAsked { detailBlock("Last asked", asked) }
                    if s.recap == nil && s.lastAsked == nil { detailBlock("Where it is", s.empty ? "Nothing has been asked in this session yet." : "No recap saved for this session yet.") }
                    HStack(spacing: 8) {
                        action(s.status == "closed" ? "Reopen" : "Go to session", primary: true) { app?.go(s) }
                        action(model.pinned.contains(s.id) ? "Unpin" : "Pin") { model.togglePin(s.id) }
                        if !s.empty { action("Copy resume") { copyResume(s) } }
                    }
                    .padding(.top, 22)
                }
                .padding(22)
            }
        }
    }
    func detailBlock(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.white.opacity(0.35))
            Text(text).font(.system(size: 13)).lineSpacing(3).foregroundStyle(.white.opacity(0.82)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(.top, 20)
    }
    func action(_ label: String, primary: Bool = false, _ act: @escaping () -> Void) -> some View {
        Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(primary ? Color.black : .white.opacity(0.85))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(primary ? Color.white.opacity(0.92) : Color.white.opacity(0.1)))
            .contentShape(Rectangle()).modifier(PointerLink())
            .onTapGesture(perform: act)
    }

    @ViewBuilder var panelBody: some View {
        let closedW: CGFloat = model.notchWidth > 0 ? model.notchWidth : 160
        let closedH: CGFloat = model.notchWidth > 0 ? model.barHeight : 0
        VStack(spacing: 0) {
            pill.frame(height: model.barHeight)
            list
        }
        .frame(width: Self.openWidth, height: Self.openHeight, alignment: .top)
        .overlay(alignment: .bottom) { closedToast }
        .opacity(model.open ? 1 : 0)
        .frame(width: model.open ? Self.openWidth : closedW, height: model.open ? Self.openHeight : closedH, alignment: .top)
        // Dark frosted glass: the system blur of whatever is behind, darkened, and solid black at the very top so it joins the notch.
        .background(
            ZStack {
                GlassBack(shape: Rectangle(), dim: 0.4, frosted: Color.black.opacity(0.42), shade: 0.2)
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.075), .init(color: .black.opacity(0), location: 0.2)], startPoint: .top, endPoint: .bottom)
            }
            .environment(\.colorScheme, .dark)
        )
        .clipShape(UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: model.open ? 18 : 9, bottomTrailing: model.open ? 18 : 9)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var dots: some View {
        PortalMark(active: model.active.count)
    }
    var brand: some View {
        HStack(spacing: 8) {
            dots
            // Beside the portal: the session that most recently asked for you, or failing that the one working now.
            if let s = model.spotlight {
                HStack(spacing: 5) {
                    Text(["needs you", "finished", "working", ""][s.rank]).foregroundStyle(s.rank == 0 ? PortalMark.lavender : .white.opacity(0.5))
                    Text(s.title).foregroundStyle(.white.opacity(0.88)).lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 11.5, weight: .medium))
                .contentShape(Rectangle())
                .modifier(PointerLink())
                .onTapGesture { app?.go(s) }
            }
        }
    }
    var stats: some View {
        Text(model.summary).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).fixedSize()
    }
    @ViewBuilder var pill: some View {
        if model.notchWidth > 0 {
            // Either side of the camera: the stats on its left, the portal on its right.
            let side = (Self.openWidth - model.notchWidth) / 2
            HStack(spacing: 0) {
                brand.padding(.leading, 18).frame(width: side, alignment: .leading)
                Color.clear.frame(width: model.notchWidth)
                stats.padding(.trailing, 18).frame(width: side, alignment: .trailing)
            }
        } else {
            HStack { brand; Spacer(); stats }.padding(.horizontal, 18)
        }
    }

    var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
                TextField("", text: $model.query, prompt: Text("Search sessions").foregroundStyle(.white.opacity(0.35)))
                    .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(.white).tint(.white)
                    .focused($searchFocused)
                if showMic {
                    Image(systemName: dictation.listening ? "mic.fill" : "mic").font(.system(size: 13))
                        .foregroundStyle(dictation.listening ? PortalMark.lavender : .white.opacity(0.45))
                        .contentShape(Rectangle().inset(by: -6))
                        .onTapGesture { dictation.toggle() }
                        .help("Speak your search")
                }
                if !detached {
                    Image(systemName: "macwindow.on.rectangle").font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
                        .contentShape(Rectangle().inset(by: -6))
                        .onTapGesture { app?.toggleWidget() }
                        .help("Keep a copy on screen that you can move to another display")
                }
                gear
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
            .onChange(of: model.open) { _, isOpen in searchFocused = isOpen }
            .onChange(of: model.query) { _, _ in model.selected = 0 }
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            GeometryReader { geo in
                let rows = model.filtered
                ScrollView {
                    Group {
                        // Narrow: one column, repos one under another.
                        VStack(spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, s in
                                if i == 0 || rows[i - 1].project != s.project {
                                    repoHeader(s.project, count: rows.filter { $0.project == s.project }.count).padding(.top, i == 0 ? 4 : 14)
                                }
                                row(s, selected: i == model.selected && !detached)
                            }
                            // Sessions that are no longer open. Clicking one reopens it in a new terminal.
                            let past = model.recentHits
                            if !past.isEmpty {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                                    Text("Recently closed").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                                    Text("click to reopen").font(.system(size: 11)).foregroundStyle(.white.opacity(0.25))
                                    Spacer()
                                }.padding(.horizontal, 12).padding(.top, rows.isEmpty ? 4 : 14).padding(.bottom, 2)
                                ForEach(past) { s in row(s, selected: false, showRepo: true) }
                            }
                        }.padding(8)
                    }
                }
            }
        }
        .frame(height: detached ? nil : Self.openHeight - model.barHeight)
    }

    func repos(in rows: [Session]) -> [String] { var out: [String] = []; for s in rows where !out.contains(s.project) { out.append(s.project) }; return out }

    func repoHeader(_ name: String, count: Int) -> some View {
        HStack {
            RepoIcon().stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 1.05, lineCap: .round, lineJoin: .round)).frame(width: 10.5, height: 10.5)
            Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            Text("\(count)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.25))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.bottom, 3)
    }

    func row(_ s: Session, selected: Bool, showRepo: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Group {
                if s.rank == 2 { Orb() }
                else if s.rank == 0 { Orb(spinning: false) }
                else if s.rank == 1 { Orb(spinning: false, tint: Color(white: 0.85), glow: 0.5) }
                else { Orb(spinning: false, tint: Color(white: 0.55), size: 8, glow: 0).opacity(0.55) }
            }.frame(width: 12, height: 12).padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(s.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                    if model.mixed {
                        Text(s.tool == "codex" ? "Codex" : "Claude").font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(.white.opacity(0.09))).fixedSize()
                    }
                }
                (repoText(showRepo ? s.project : "") + Text((showRepo ? "  ·  " : "") + "\(s.statusText) \(s.age)") + branchText(s.branch, lead: "  ·  "))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                // In the notch panel: the last thing you typed there, on one line, cut short if it is long.
                if !detached, showLast, let asked = s.lastAsked {
                    Text(asked).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.62)).lineLimit(1).truncationMode(.tail)
                }
                // Where the session is. Shown in the stay-on-screen window, where there is room for it.
                if detached, let recap = s.gist {
                    Text(recap).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.66)).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
            }
            Spacer()
            closeControl(s)
            if model.pinned.contains(s.id) { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.35)).padding(.top, 4) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(selected ? 0.11 : hovered == s.id ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = s.id; NSCursor.pointingHand.set() } else if hovered == s.id { hovered = nil; confirmClose = nil; NSCursor.arrow.set() }
        }
        .modifier(PointerLink())
        .onTapGesture { dbg("row clicked: \(s.title)"); app?.go(s) }
        .contextMenu {
            Button(model.pinned.contains(s.id) ? "Unpin" : "Pin to top") { model.togglePin(s.id) }
            if !s.empty {
                Button("Copy resume command") {
                    let cmd = s.tool == "codex" ? "codex resume \(s.id.replacingOccurrences(of: "codex-", with: ""))" : "claude --resume \(s.id)"
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
                }
            }
            Button("Show folder in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.cwd) }
        }
    }
}

/// One orb for every state, so they belong together: a swirl of light around a bright core.
/// Working turns and breathes. Needs-you is the same orb held still. Idle is a small dim grey one.
struct Orb: View {
    var spinning = true
    var tint: Color = PortalMark.lavender
    var size: CGFloat = 11
    var glow: Double = 1
    @State private var spin = false
    @State private var breathe = false
    var body: some View {
        ZStack {
            Circle().fill(AngularGradient(colors: [.white, tint, .white.opacity(0.08), tint.opacity(0.6), .white], center: .center))
                .rotationEffect(.degrees(spinning ? (spin ? 360 : 0) : 35))
            Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: size * 0.3))
        }
        .frame(width: size, height: size)
        .scaleEffect(spinning ? (breathe ? 1.08 : 0.92) : 1)
        .shadow(color: tint.opacity(glow * (spinning ? (breathe ? 0.95 : 0.45) : 0.6)), radius: glow > 0 ? 5 : 0)
        .onAppear {
            guard spinning else { return }
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// A pointing-hand cursor over things you can click.
struct PointerLink: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.pointerStyle(.link) }
        else { content.onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() } }
    }
}

/// The fathomed portal arch. Dim when nothing is happening; glows and shows a count when sessions are active.
/// The surface behind the panel and the window: Liquid Glass on macOS 26 and later, darkened so white text
/// stays readable over anything; the older frosted blur everywhere else.
struct GlassBack<S: Shape>: View {
    let shape: S
    let dim: Double
    let frosted: Color
    /// Extra black laid over the glass. The system turns glass pale when its window is not the focused one,
    /// and the stay-on-screen window almost never is, so its darkness cannot be left to the glass alone.
    var shade: Double = 0
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            ZStack { Color.clear.glassEffect(.regular.tint(Color.black.opacity(dim)), in: shape); shape.fill(Color.black.opacity(shade)) }
        } else {
            old
        }
        #else
        old
        #endif
    }
    var old: some View { ZStack { shape.fill(.ultraThinMaterial); shape.fill(frosted) } }
}

/// The usual git-branch mark: a line between two dots, with a third dot branching off to the right.
/// Drawn here because the system symbol set has no match for it.
enum BranchIcon {
    /// Text does not tint an image placed inside it, so the mark is drawn in the text's own shade of white.
    static var made: [Double: NSImage] = [:]
    static func image(_ tone: Double) -> NSImage {
        if let i = made[tone] { return i }
        let size: CGFloat = 12, k = size / 16
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let t = NSAffineTransform(); t.scale(by: k); t.concat()
            NSColor.white.withAlphaComponent(tone).setStroke()
            let p = NSBezierPath(); p.lineWidth = 1.9; p.lineCapStyle = .round
            for c in [NSPoint(x: 4.25, y: 3.25), NSPoint(x: 4.25, y: 12.75), NSPoint(x: 11.75, y: 3.25)] {
                p.appendOval(in: NSRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3))
            }
            p.move(to: NSPoint(x: 4.25, y: 4.75)); p.line(to: NSPoint(x: 4.25, y: 11.25))
            p.move(to: NSPoint(x: 11.75, y: 4.75)); p.line(to: NSPoint(x: 11.75, y: 6))
            p.curve(to: NSPoint(x: 10, y: 7.75), controlPoint1: NSPoint(x: 11.75, y: 7), controlPoint2: NSPoint(x: 11, y: 7.75))
            p.line(to: NSPoint(x: 6, y: 7.75))
            p.curve(to: NSPoint(x: 4.25, y: 9.5), controlPoint1: NSPoint(x: 5, y: 7.75), controlPoint2: NSPoint(x: 4.25, y: 8.5))
            p.stroke()
            return true
        }
        made[tone] = img
        return img
    }
}

/// The repository mark as an image, for placing inside a line of text beside a repo name.
enum RepoGlyph {
    static var made: [Double: NSImage] = [:]
    static func image(_ tone: Double) -> NSImage {
        if let i = made[tone] { return i }
        let size: CGFloat = 11.5, k = size / 16
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let t = NSAffineTransform(); t.scale(by: k); t.concat()
            NSColor.white.withAlphaComponent(tone).setStroke()
            let p = NSBezierPath(roundedRect: NSRect(x: 2.75, y: 1.5, width: 10.5, height: 12.5), xRadius: 1.6, yRadius: 1.6)
            p.lineWidth = 1.6; p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.move(to: NSPoint(x: 2.75, y: 10.5)); p.line(to: NSPoint(x: 13.25, y: 10.5))
            p.move(to: NSPoint(x: 5.5, y: 12.3)); p.line(to: NSPoint(x: 5.5, y: 15.4)); p.line(to: NSPoint(x: 7, y: 14.4)); p.line(to: NSPoint(x: 8.5, y: 15.4)); p.line(to: NSPoint(x: 8.5, y: 12.3))
            p.stroke()
            return true
        }
        made[tone] = img
        return img
    }
}

/// The usual repository mark: a closed book with a band across the foot and a bookmark hanging from it.
struct RepoIcon: Shape {
    func path(in r: CGRect) -> Path {
        let k = min(r.width, r.height) / 16
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * k) }
        var p = Path()
        p.addRoundedRect(in: CGRect(x: r.minX + 2.75 * k, y: r.minY + 1.5 * k, width: 10.5 * k, height: 12.5 * k), cornerSize: CGSize(width: 1.6 * k, height: 1.6 * k))
        p.move(to: pt(2.75, 10.5)); p.addLine(to: pt(13.25, 10.5))
        p.move(to: pt(5.5, 12.3)); p.addLine(to: pt(5.5, 15.6)); p.addLine(to: pt(7, 14.5)); p.addLine(to: pt(8.5, 15.6)); p.addLine(to: pt(8.5, 12.3))
        return p
    }
}

struct Arch: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); let rad = r.width / 2
        p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
        p.addArc(center: CGPoint(x: r.midX, y: r.minY + rad), radius: rad, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        return p
    }
}
struct PortalMark: View {
    let active: Int
    @State private var pulse = false
    static let lavender = Color(red: 0.65, green: 0.62, blue: 0.94)
    // Loaded from inside the app itself, never from the project folder.
    static let image: NSImage? = Bundle.main.url(forResource: "portal", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        Group {
            if let img = Self.image {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
            } else {
                Arch().stroke(Self.lavender, style: StrokeStyle(lineWidth: 1.8, lineCap: .round)).frame(width: 10, height: 13)
            }
        }
        // The doorway brightens and dims slowly while any session is working or has just asked for you.
        .shadow(color: Self.lavender.opacity(active > 0 ? (pulse ? 0.95 : 0.3) : 0.15), radius: active > 0 ? 7 : 3)
        .onAppear { withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

// ── dictation: Apple's speech recognition, on this Mac, straight into the search field ──
final class Dictation: NSObject, ObservableObject {
    @Published var listening = false
    var onText: (String) -> Void = { _ in }
    var words: [String] = []   // repo names and titles, so they are heard correctly
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() { listening ? stop() : start() }
    func start() {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { NSLog("speech recognition not allowed"); return }
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                guard ok else { NSLog("microphone not allowed"); return }
                DispatchQueue.main.async { self.begin() }
            }
        }
    }
    private func begin() {
        guard let recognizer, recognizer.isAvailable, !listening else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.contextualStrings = words
        request = req
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
        engine.prepare()
        do { try engine.start() } catch { NSLog("audio engine: \(error)"); return }
        listening = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            if let r = result { DispatchQueue.main.async { self?.onText(r.bestTranscription.formattedString) } }
            if error != nil || result?.isFinal == true { DispatchQueue.main.async { self?.stop() } }
        }
    }
    func stop() {
        guard listening else { return }
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.cancel(); task = nil; request = nil; listening = false
    }
}

// ── the window, the hotkey and what keys do ──
final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
/// Lets the very first click on the panel count as a click, instead of only waking the window up.
final class FirstClickHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate!
    let model = Model()
    var panel: KeyPanel!
    var screen: NSScreen = NSScreen.main ?? NSScreen.screens[0]
    var byHover = false
    var hotKey: EventHotKeyRef?
    let queue = DispatchQueue(label: "sessions")
    let dictation = Dictation()

    func applicationDidFinishLaunching(_ note: Notification) {
        AppDelegate.shared = self
        Prefs.register()
        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.contentView = FirstClickHost(rootView: RootView(model: model, dictation: dictation, app: self))
        place()   // nothing is shown until the hotkey is pressed
        dictation.onText = { [weak self] t in self?.model.query = t.trimmingCharacters(in: .punctuationCharacters) }
        registerHotKey()
        // For checking by screenshot: show the panel for a few seconds without taking the keyboard.
        // For checking by screenshot: open without taking the keyboard and stay open until the app is stopped.
        // For testing the close routine on a process that is not a real session: --test-close <pid>
        if let i = CommandLine.arguments.firstIndex(of: "--test-close"), i + 1 < CommandLine.arguments.count, let pid = Int32(CommandLine.arguments[i + 1]) {
            queue.async { Closer.close(pid) }
        }
        if CommandLine.arguments.contains("--settings") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.settingsWindow == nil ? self.showSettingsQuietly() : () } }
        if CommandLine.arguments.contains("--hold") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.peeking = true; self.open(byHover: true) } }
        if CommandLine.arguments.contains("--widget") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.toggleWidget() } }
        if CommandLine.arguments.contains("--peek") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.peeking = true; self.open(byHover: true); DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.peeking = false; self.close() } } }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.key(e) == true ? nil : e }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in if self?.model.open == true { self?.close() } }
        refresh()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.trackMouse() }
    }

    func refresh() {
        if Demo.on {
            let s = Demo.sessions()
            model.sessions = s; model.recent = Prefs.bool("showRecent") ? Demo.closed() : []
            model.currentId = s.first { $0.id == "d2" }?.id
            if model.open && !movedSelection && model.query.isEmpty { model.selected = model.filtered.firstIndex { $0.id == model.currentId } ?? -1 }
            return
        }
        queue.async {
            let hide = Prefs.hiddenRepos
            let s = Loader.load().filter { !hide.contains($0.project.lowercased()) }
            let past = (Prefs.bool("showRecent") ? Loader.recent(excluding: Set(s.map(\.id))) : []).filter { !hide.contains($0.project.lowercased()) }
            let here = Loader.currentSession(among: s)
            if let here { Seen.at[here] = Date().timeIntervalSince1970 * 1000 }
            DispatchQueue.main.async {
                self.model.sessions = s; self.model.recent = past; self.model.currentId = here; self.dictation.words = Array(Set(s.map(\.project) + s.map(\.title)))
                // Keep the highlight on the session you are in as fresh data arrives, until you move it yourself.
                if self.model.open && !self.movedSelection && self.model.query.isEmpty {
                    self.model.selected = self.model.filtered.firstIndex { $0.id == here } ?? -1
                }
            }
        }
    }

    /// Top centre of the screen. The window is always panel-sized; it is only on screen while open or animating.
    func place() {
        let bar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        var notch: CGFloat = 0
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea { notch = max(0, screen.frame.width - l.width - r.width) }
        model.barHeight = bar; model.notchWidth = notch
        let size = NSSize(width: RootView.openWidth, height: RootView.openHeight)
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    var movedSelection = false   // you have moved the highlight with the arrow keys since the panel opened
    func open(byHover: Bool) {
        if !model.open { movedSelection = false }
        refresh()   // Read the session list now, so the panel is never up to three seconds stale when it appears.
        guard !model.open else { return }
        self.byHover = byHover
        screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? screen
        model.query = ""
        // Start on the session you are in. If that isn't known, start with nothing picked, so the highlight never claims a session is the current one.
        model.selected = model.filtered.firstIndex { $0.id == model.currentId } ?? -1
        place()
        // Always take focus, even when opened by the pointer: a window that isn't focused swallows the first click and won't change the cursor.
        if peeking { panel.orderFrontRegardless() } else { panel.makeKeyAndOrderFront(nil) }
        DispatchQueue.main.async { withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { self.model.open = true } }
    }
    func close() {
        guard model.open else { return }
        dictation.stop()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.95)) { model.open = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { if !self.model.open { self.panel.orderOut(nil) } }
    }
    /// Pushing the pointer into the top centre of the screen opens the panel; moving away from it closes it again.
    var dwell = 0
    var peeking = false
    func trackMouse() {
        let m = NSEvent.mouseLocation
        if !model.open {
            guard Prefs.bool("openOnHover") else { return }
            guard let s = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) else { return }
            var w: CGFloat = 200
            if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea { w = max(120, s.frame.width - l.width - r.width) }
            if m.y >= s.frame.maxY - 4 && abs(m.x - s.frame.midX) < w / 2 { dwell += 1; if dwell >= 2 { dwell = 0; open(byHover: true) } } else { dwell = 0 }
        } else if byHover, !peeking, !panel.frame.insetBy(dx: -24, dy: -24).contains(m) {
            close()
        }
    }

    func toggle() { model.open ? close() : open(byHover: false) }

    /// A second copy of the list in an ordinary Mac window that stays on screen: the usual close, minimise and
    /// full-screen buttons, draggable to any display, resizable, and it remembers where it was.
    var widget: NSWindow?
    static let widgetMin = NSSize(width: 440, height: 320)
    // The window's own minimum size does not survive SwiftUI hosting, so the limit is enforced as it is dragged.
    func windowWillResize(_ sender: NSWindow, to size: NSSize) -> NSSize {
        NSSize(width: max(size.width, Self.widgetMin.width), height: max(size.height, Self.widgetMin.height))
    }
    func toggleWidget() {
        if let w = widget { w.close(); return }
        let s = NSScreen.screens.last ?? screen
        let w = NSWindow(contentRect: NSRect(x: s.visibleFrame.maxX - 420, y: s.visibleFrame.maxY - 600, width: 460, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.title = "fathomed"
        w.appearance = NSAppearance(named: .darkAqua)
        w.isOpaque = false; w.backgroundColor = .clear
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.level = Prefs.bool("widgetOnTop") ? .floating : .normal
        w.collectionBehavior = [.fullScreenPrimary]
        let host = FirstClickHost(rootView: RootView(model: model, dictation: dictation, app: self, detached: true))
        // Otherwise SwiftUI replaces the window's minimum size with the content's own, which is far too small.
        host.sizingOptions = []
        w.contentView = host
        w.contentMinSize = NSSize(width: 440, height: 320)
        w.delegate = self
        w.setFrameAutosaveName("fathomedWidget")
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in self?.widget = nil }
        w.orderFrontRegardless()
        widget = w
        close()
    }

    func key(_ e: NSEvent) -> Bool {
        guard model.open else { return false }
        let n = model.filtered.count
        switch Int(e.keyCode) {
        case kVK_Escape: close()
        case kVK_DownArrow: movedSelection = true; if n > 0 { model.selected = min(n - 1, model.selected + 1) }
        case kVK_UpArrow: movedSelection = true; model.selected = max(0, model.selected - 1)
        case kVK_Return: if model.selected >= 0 && model.selected < n { go(model.filtered[model.selected]) }
        default: return false   // everything else is typing, and goes to the search field
        }
        return true
    }

    /// Bring the window that holds this session to the front.
    /// Close a session from the panel or the window.
    func end(_ s: Session) {
        if Demo.on {   // a sample session just leaves the list
            Demo.hidden.insert(s.id)
            withAnimation(.easeInOut(duration: 0.2)) { model.closed = (s.title, "claude --resume sample") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { withAnimation { self.model.closed = nil } }
            refresh(); return
        }
        dbg("end: \(s.title) pid \(s.pid)")
        withAnimation(.easeInOut(duration: 0.2)) { model.closed = s.empty ? nil : (s.title, s.resumeCommand) }
        let title = s.title
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if self.model.closed?.title == title { withAnimation { self.model.closed = nil } } }
        queue.async { Closer.close(s.pid); self.refresh() }
    }
    /// Reopen a closed session: bring its project's editor window forward (opening it if need be), then ask the
    /// helper in that window to start a terminal and resume the conversation there.
    func resume(_ s: Session) {
        dbg("resume: \(s.title) \(s.id) in \(s.cwd)")
        close()
        queue.async {
            // The editor you last jumped into from here; failing that, the first one installed.
            let known = [("Cursor", "cursor"), ("Visual Studio Code", "vscode"), ("Windsurf", "windsurf"), ("VSCodium", "vscodium")]
            var app = UserDefaults.standard.string(forKey: "lastEditorApp"), scheme = UserDefaults.standard.string(forKey: "lastEditorScheme")
            if let pick = Prefs.editors.first(where: { $0.id == Prefs.string("reopenIn") }) { app = pick.app; scheme = pick.scheme }
            if app == nil || !FileManager.default.fileExists(atPath: app!) {
                let hit = known.first { FileManager.default.fileExists(atPath: "/Applications/\($0.0).app") }
                app = hit.map { "/Applications/\($0.0).app" }; scheme = hit?.1
            }
            func run(_ args: [String]) {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = args
                do { try p.run(); p.waitUntilExit(); dbg("resume: open \(args.last ?? "") exited \(p.terminationStatus)") } catch { dbg("resume: open failed \(error)") }
            }
            guard let app, let scheme else {
                // No editor with the helper: leave the command on the clipboard to paste into any terminal.
                DispatchQueue.main.async { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("cd \"\(s.cwd)\" && \(s.resumeCommand)", forType: .string); NSSound.beep() }
                return
            }
            run(["-a", app, s.cwd])
            var q = URLComponents(); q.queryItems = [URLQueryItem(name: "tool", value: s.tool), URLQueryItem(name: "id", value: s.id.replacingOccurrences(of: "codex-", with: "")), URLQueryItem(name: "cwd", value: s.cwd)]
            let link = "\(scheme)://fathomed.fathomed-portal-helper/resume?" + (q.percentEncodedQuery ?? "")
            // Sent several times: the window may still be opening. The helper acts on the first one that reaches the
            // right window and ignores the rest.
            var last = 0.0
            for at in [0.6, 1.5, 3.5, 7.0] { Thread.sleep(forTimeInterval: at - last); last = at; run(["-g", link]) }
            Loader.recentCache.at = 0
            self.refresh()
        }
    }
    func go(_ s: Session) {
        if Demo.on { close(); return }
        if s.status == "closed" { resume(s); return }
        dbg("go: \(s.title) pid \(s.pid)")
        Seen.at[s.id] = Date().timeIntervalSince1970 * 1000; refresh()
        close()
        queue.async {
            let (found, chain) = Loader.owner(of: s.pid)
            guard let app = found else { dbg("go: no owning app found"); NSSound.beep(); return }
            let name = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
            // Editors that open folders, and the link prefix each one answers to.
            let editors = ["Cursor": "cursor", "Code": "vscode", "Visual Studio Code": "vscode", "Windsurf": "windsurf", "VSCodium": "vscodium", "Code - Insiders": "vscode-insiders"]
            func run(_ args: [String]) {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = args
                do { try p.run(); p.waitUntilExit(); dbg("go: open \(args.last ?? "") exited \(p.terminationStatus)") } catch { dbg("go: open failed \(error)") }
            }
            guard let scheme = editors[name] else { run(["-a", app]); return }
            UserDefaults.standard.set(app, forKey: "lastEditorApp"); UserDefaults.standard.set(scheme, forKey: "lastEditorScheme")
            run(["-a", app, s.cwd])
            // Then ask the helper inside the editor (if installed) to show the terminal tab this session is running in.
            // Sent twice, because the first can arrive before the right window has come forward.
            let link = "\(scheme)://fathomed.fathomed-portal-helper/focus?pids=" + chain.map(String.init).joined(separator: ",")
            for delay in [0.35, 1.0] { Thread.sleep(forTimeInterval: delay); run(["-g", link]) }
        }
    }

    var hotKeyHandler = false
    /// Sets the shortcut chosen in settings, replacing whichever was set before.
    func registerHotKey() {
        if !hotKeyHandler {
            hotKeyHandler = true
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { AppDelegate.shared.toggle() }
                return noErr
            }, 1, &type, nil, nil)
        }
        if let old = hotKey { UnregisterEventHotKey(old); hotKey = nil }
        guard let pick = Prefs.hotkeys.first(where: { $0.id == Prefs.string("hotkey") }), pick.id != "none" else { return }
        RegisterEventHotKey(UInt32(pick.key), UInt32(pick.mods), EventHotKeyID(signature: OSType(0x46544850), id: 1), GetApplicationEventTarget(), 0, &hotKey)
    }

    /// For screenshots: put the settings window on screen without taking the keyboard.
    func showSettingsQuietly() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "fathomed settings"; w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView(app: self))
        w.center(); settingsWindow = w; w.orderFrontRegardless()
    }
    var settingsWindow: NSWindow?
    func showSettings() {
        close()
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "fathomed settings"; w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(app: self))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
