// Throwaway test: a pill at the top of the screen that drops down a list of live Claude Code sessions.
// Not the real app. It exists to show what building and running a native Mac app feels like.
import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

/// Notes for working out what went wrong, written to a file next to the build.
// Kept out of Documents on purpose: macOS asks for permission before an app touches that folder.
let dbgPath = NSHomeDirectory() + "/Library/Logs/codehatch.log"
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
    /// True when the session runs in the Claude Code editor extension's chat panel, not in a terminal tab.
    var inPanel = false
    var title: String
    var waitingFor: String? = nil
    var recap: String? = nil      // where the session is: Claude Code's own saved recap
    var lastAsked: String? = nil  // the most recent thing you typed in it
    var lastReply: String? = nil  // the most recent thing the agent said back
    var replyIsNewer = false      // true when the agent spoke after your last message
    /// The last thing said in the session, by either side. Yours is marked "You:", as chat lists do.
    var lastMessage: String? {
        if replyIsNewer, let lastReply { return lastReply }
        return lastAsked.map { "You: " + $0 } ?? lastReply
    }
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
    /// The home folder everything is read from. Tests point CODEHATCH_HOME at a stand-in folder, so they can lay out
    /// pretend session files without going near the real ones.
    static let home: URL = ProcessInfo.processInfo.environment["CODEHATCH_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
    static var titleCache: [String: (size: UInt64, title: String?)] = [:]

    static func load() -> [Session] {
        let dir = home.appendingPathComponent(".claude/sessions")
        // No Claude Code on this Mac is not a reason to stop: there may still be Codex sessions.
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [Session] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = o["pid"] as? Int, kill(Int32(pid), 0) == 0,
                  let sid = o["sessionId"] as? String else { continue }
            let cwd = o["cwd"] as? String ?? ""
            let updated = (o["statusUpdatedAt"] as? Double) ?? (o["updatedAt"] as? Double) ?? 0
            let found = title(for: sid, cwd: cwd)
            // A name you gave it yourself (with /rename) wins over the title Claude Code wrote for it. The name in
            // the session file is only a placeholder like "repo-6f" when its source is "derived".
            let given = (o["nameSource"] as? String).flatMap { $0 == "derived" ? nil : o["name"] as? String }.flatMap { $0.isEmpty ? nil : $0 }
            var s = Session(id: sid, pid: Int32(pid), cwd: cwd, status: o["status"] as? String ?? "idle", updatedAt: updated, title: given ?? found ?? "New session")
            s.empty = found == nil
            s.waitingFor = o["waitingFor"] as? String
            s.inPanel = (o["entrypoint"] as? String) == "claude-vscode"
            s.startedAt = o["startedAt"] as? Double ?? 0
            let ex = extras(for: sid, cwd: cwd); s.recap = ex.recap; s.branch = ex.branch; s.lastAsked = ex.asked; s.lastReply = ex.reply; s.replyIsNewer = ex.newer
            out.append(s)
        }
        out += Codex.load()
        Hooks.overlay(&out)
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
            let ex = extras(for: sid, cwd: cwd); s.recap = ex.recap; s.branch = ex.branch; s.lastAsked = ex.asked; s.lastReply = ex.reply; s.replyIsNewer = ex.newer
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
        if let data = added(to: url, since: t == nil ? nil : titleCache[sid]?.size, now: size),
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
    static var extraCache: [String: (size: UInt64, recap: String?, branch: String?, asked: String?, reply: String?, newer: Bool)] = [:]
    /// The part of a history file written since it was last read, or the whole file the first time.
    static func added(to url: URL, since old: UInt64?, now size: UInt64) -> Data? {
        guard let old, old > 0, size > old else { return try? Data(contentsOf: url, options: .mappedIfSafe) }
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        try? h.seek(toOffset: old)
        return try? h.readToEnd()
    }
    static func extras(for sid: String, cwd: String) -> (recap: String?, branch: String?, asked: String?, reply: String?, newer: Bool) {
        let esc = cwd.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        let url = home.appendingPathComponent(".claude/projects/\(esc)/\(sid).jsonl")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? UInt64 else { return (nil, nil, nil, nil, false) }
        if let c = extraCache[sid], c.size == size { return (c.recap, c.branch, c.asked, c.reply, c.newer) }
        // A history file only grows. Once it has been read, only what was added since is read again; whatever
        // is not found in the new part keeps its earlier value. Working sessions grow every few seconds and
        // their files reach tens of megabytes, so rereading the whole file each time is far too much work.
        let old = extraCache[sid]
        var recap = old?.recap, branch = old?.branch, asked = old?.asked, reply = old?.reply, newer = old?.newer ?? false
        if let data = added(to: url, since: old?.size, now: size) {
            // Claude Code writes a short recap into the history when a session has been left for a few minutes.
            if let hit = lastLine(in: data, containing: "\"subtype\":\"away_summary\""), let text = hit.obj["content"] as? String { recap = text }
            if let r = data.range(of: Data("\"gitBranch\":\"".utf8), options: .backwards), let q = data[r.upperBound...].firstIndex(of: UInt8(ascii: "\"")) {
                branch = String(decoding: data[r.upperBound..<q], as: UTF8.self)
            }
            // The last thing each side said, and which of the two came later in the file.
            let you = lastPrompt(in: data), them = lastReply(in: data)
            if let you { asked = you.text }
            if let them { reply = them.text }
            if let you, let them { newer = them.at > you.at } else if them != nil { newer = true } else if you != nil { newer = false }
        }
        extraCache[sid] = (size, recap, branch, asked, reply, newer)
        return (recap, branch, asked, reply, newer)
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
    /// A message as one run of plain text: its lines joined, and the marks of formatting (bold, headings, bullets,
    /// code ticks) taken out, so a row can show as much of it as fits and not just a short first line.
    static func flat(_ text: String) -> String {
        let lines = text.split(separator: "\n").map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            l = l.replacingOccurrences(of: #"^(#{1,6}\s+|[-*•]\s+|\d+\.\s+|>\s+)"#, with: "", options: .regularExpression)
            return l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        }.filter { !$0.isEmpty && !$0.hasPrefix("|") && !$0.hasPrefix("---") }
        let one = lines.joined(separator: " ")
        return one.count > 400 ? String(one.prefix(399)) + "…" : one
    }
    /// The most recent thing the agent said in words (not a tool call), and where in the file it is.
    static func lastReply(in data: Data) -> (text: String, at: Data.Index)? {
        var before: Data.Index? = nil
        for _ in 0..<40 {
            guard let hit = lastLine(in: data, containing: "\"type\":\"assistant\"", before: before) else { return nil }
            before = hit.start
            guard hit.obj["type"] as? String == "assistant", let m = hit.obj["message"] as? [String: Any], let parts = m["content"] as? [[String: Any]] else { continue }
            let said = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: " ")
            let one = flat(said)
            guard !one.isEmpty else { continue }
            return (one, hit.start)
        }
        return nil
    }
    static func lastPrompt(in data: Data) -> (text: String, at: Data.Index)? {
        var before: Data.Index? = nil
        for _ in 0..<40 {
            guard let hit = lastLine(in: data, containing: "\"type\":\"user\"", before: before) else { return nil }
            before = hit.start
            let o = hit.obj
            guard o["isMeta"] as? Bool != true, let m = o["message"] as? [String: Any] else { continue }
            var text: String? = m["content"] as? String
            if text == nil, let parts = m["content"] as? [[String: Any]] { text = parts.first { $0["type"] as? String == "text" }?["text"] as? String }
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("["), !t.hasPrefix("This session is being continued from a previous conversation") else { continue }
            return (flat(t), hit.start)
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
        let url = home.appendingPathComponent(".codehatch/active-terminal.json")
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

// ── state the interface draws from ──
final class Model: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var open = false
    @Published var selected = 0
    @Published var query = ""
    /// The session just closed from here, shown briefly so a slip can be undone by resuming it.
    @Published var closed: (title: String, command: String, session: Session?)? = nil
    /// Closed sessions that can be reopened, newest first.
    @Published var recent: [Session] = []
    var recentHits: [Session] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let found = words.isEmpty ? recent : recent.filter { s in let hay = (s.title + " " + s.project + " " + (s.branch ?? "")).lowercased(); return words.allSatisfy { hay.contains($0) } }
        return repoFilter.map { only in only == Model.closedOnly ? found : found.filter { $0.project == only } } ?? found
    }
    /// The filter value that shows only recently closed sessions.
    static let closedOnly = "\u{0}closed"
    /// The repo picked from the chips under the search box, or nil for all of them.
    @Published var repoFilter: String? = nil
    /// The width of the notch the status tab sits beside (the built-in display's), or 0 on a Mac without one.
    @Published var beaconNotch: CGFloat = 0
    /// The repos that have open sessions, the most recently touched first, for the filter chips.
    var repoNames: [String] {
        var out: [String] = []
        for s in sessions.sorted(by: { max($0.updatedAt, Seen.at[$0.id] ?? 0) > max($1.updatedAt, Seen.at[$1.id] ?? 0) }) where !out.contains(s.project) { out.append(s.project) }
        return out
    }
    @Published var currentId: String?   // the session you are in, when the editor helper can tell us
    @Published var notchWidth: CGFloat = 0
    /// The notch's own height, which can be a point less than the menu bar's (33 against 34 here).
    @Published var notchHeight: CGFloat = 0
    @Published var barHeight: CGFloat = 26

    /// Sessions matching the search, most recent activity first, not grouped.
    var hits: [Session] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return words.isEmpty ? sessions : sessions.filter { s in let hay = (s.title + " " + s.project + " " + (s.branch ?? "")).lowercased(); return words.allSatisfy { hay.contains($0) } }
    }
    var filtered: [Session] {
        let q = query.lowercased()
        // Every word typed or spoken has to appear somewhere in the title or the repo name.
        let words = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var hits = words.isEmpty ? sessions : sessions.filter { s in let hay = (s.title + " " + s.project).lowercased(); return words.allSatisfy { hay.contains($0) } }
        if let only = repoFilter { hits = only == Model.closedOnly ? [] : hits.filter { $0.project == only } }
        // One flat list, most recently touched on top. "Touched" means it did something (started, finished, asked
        // for you) or you were in it. Going to a session moves that one row to the top and nothing else; there are
        // no repo groups to drag along with it. Sessions that were opened but never used sit at the bottom.
        func touched(_ s: Session) -> Double { max(s.updatedAt, Seen.at[s.id] ?? 0) }
        let byRecent = hits.sorted { (touched($0), $0.id) > (touched($1), $1.id) }
        if Prefs.string("notchOrder") == "repo" {
            // By repo, for people who think in projects. Repos are in alphabetical order and never move, so going
            // to a session cannot shove other repos around; inside each repo the order is still most recent first.
            let repos = Set(hits.map(\.project)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            return repos.flatMap { name in byRecent.filter { $0.project == name && !$0.empty } + byRecent.filter { $0.project == name && $0.empty } }
        }
        return byRecent.filter { !$0.empty } + byRecent.filter { $0.empty }
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
    /// The same counts from fullest to shortest, for a space that may not fit them all. What needs you is kept longest.
    var summaries: [String] {
        let w = sessions.filter { $0.rank == 2 }.count, n = sessions.filter { $0.rank == 0 }.count, f = sessions.filter { $0.rank == 1 }.count
        let needs = n > 0 ? "\(n) need\(n == 1 ? "s" : "") you" : nil, fin = f > 0 ? "\(f) finished" : nil, work = w > 0 ? "\(w) working" : nil, open = "\(sessions.count) open"
        let tries: [[String?]] = [[needs, fin, work, open], [needs, fin, work], [needs, work], [needs ?? fin ?? work ?? open]]
        var out: [String] = []
        for t in tries { let line = t.compactMap { $0 }.joined(separator: " · "); if !line.isEmpty, !out.contains(line) { out.append(line) } }
        return out
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

/// What the interface would show right now, written out as JSON for the tests.
enum Dump {
    static func row(_ s: Session) -> [String: Any] {
        ["id": s.id, "title": s.title, "repo": s.project, "cwd": s.cwd, "tool": s.tool, "status": s.status, "state": s.status == "closed" ? "closed" : ["needs you", "finished", "working", "idle", "unused"][s.rank],
         "waitingFor": s.waitingFor ?? "", "branch": s.branch ?? "", "lastAsked": s.lastAsked ?? "", "lastMessage": s.lastMessage ?? "", "recap": s.recap ?? "", "empty": s.empty, "pid": Int(s.pid)]
    }
    static func run() {
        let hide = Prefs.hiddenRepos
        let sessions = Labels.apply(Loader.load().filter { !hide.contains($0.project.lowercased()) })
        let recent = Labels.apply((Prefs.bool("showRecent") ? Loader.recent(excluding: Set(sessions.map(\.id))) : []).filter { !hide.contains($0.project.lowercased()) })
        let model = Model()
        model.sessions = sessions; model.recent = recent; model.currentId = Loader.currentSession(among: sessions)
        var out: [String: Any] = ["sessions": sessions.map(row), "order": model.filtered.map(\.id), "recent": recent.map(row), "current": model.currentId ?? "", "summary": model.summary]
        // The dashboard's groups, as the window would list them with the current filter and grouping.
        let window = RootView(model: model, app: nil, detached: true)
        out["dashboard"] = window.sessionGroups().map { ["name": $0.id, "items": $0.items.map(\.id), "unused": $0.unused.map(\.id)] as [String: Any] }
        out["closedRepos"] = window.repos(in: model.recentHits)
        out["spotlight"] = model.spotlight?.id ?? ""
        out["summaries"] = model.summaries
        var beside: [String: Any] = [:]
        for shows in ["name", "state", "orb"] {
            if let l = Beacon.label(sessions: sessions, spotlight: model.spotlight, shows: shows) { beside[shows] = ["text": l.text, "count": l.count] }
        }
        out["beside"] = beside
        out["defaults"] = Prefs.defaults
        out["menu"] = AppDelegate.menu().items.flatMap { $0.submenu?.items ?? [] }.filter { !$0.isSeparatorItem }.map { ["title": $0.title, "key": $0.keyEquivalent] }
        out["helperEditors"] = Helper.present.map(\.id)
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) { FileHandle.standardOutput.write(data); print("") }
    }
}

/// Names you give sessions from the panel or the window. They are codehatch's own: kept on this Mac, shown in place
/// of the session's title, and unknown to Claude Code and Codex.
enum Labels {
    static var all: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "labels") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "labels") }
    }
    static func apply(_ sessions: [Session]) -> [Session] {
        let names = all
        guard !names.isEmpty else { return sessions }
        return sessions.map { s in
            guard let name = names[s.id] else { return s }
            var t = Session(id: s.id, pid: s.pid, cwd: s.cwd, status: s.status, updatedAt: s.updatedAt, title: name)
            t.startedAt = s.startedAt; t.tool = s.tool; t.inPanel = s.inPanel; t.waitingFor = s.waitingFor; t.recap = s.recap
            t.lastAsked = s.lastAsked; t.lastReply = s.lastReply; t.replyIsNewer = s.replyIsNewer; t.branch = s.branch; t.empty = false
            return t
        }
    }
}

/// Terminal and iTerm2: the two terminal apps that let another app pick a tab. Each is driven through its own
/// scripting commands, matching the tab by the terminal device (tty) the session is running on. macOS asks once
/// for permission to control each app. Other terminals have no such commands, so they are only brought forward.
enum Terminals {
    static func kind(_ appPath: String) -> String? {
        let name = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return name == "Terminal" ? "terminal" : name.hasPrefix("iTerm") ? "iterm" : nil
    }
    static let paths = ["terminal": "/System/Applications/Utilities/Terminal.app", "iterm": "/Applications/iTerm.app"]
    /// The terminal device a process is attached to, like "/dev/ttys003".
    static func tty(of pid: Int32) -> String? {
        let t = Codex.shell("/bin/ps", ["-o", "tty=", "-p", "\(pid)"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.hasPrefix("?") ? nil : "/dev/" + t
    }
    @discardableResult static func script(_ source: String) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-e", source]
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        guard (try? p.run()) != nil else { return "" }
        let said = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let problem = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        dbg("terminal script -> \(said.isEmpty ? "(nothing)" : said)\(problem.isEmpty ? "" : " | " + problem.prefix(160))")
        if isDenial(problem) {
            let app = source.contains("com.googlecode.iterm2") ? "iTerm2" : "Terminal"
            DispatchQueue.main.async { AppDelegate.shared?.automationDenied(app) }
            return "denied"
        }
        return said
    }
    /// True when macOS refused to let codehatch control the app, because the person said no when asked (or later turned
    /// it off). macOS asks only once per app; after a no it never asks again, so codehatch has to say so itself.
    static func isDenial(_ error: String) -> Bool {
        error.contains("-1743") || error.localizedCaseInsensitiveContains("not authorized to send apple events") || error.localizedCaseInsensitiveContains("not allowed to send apple events")
    }
    /// Bring the tab showing this device to the front. True if it was found.
    static func focus(_ kind: String, tty: String) -> Bool {
        let source = kind == "terminal" ? """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected of t to true
                    set frontmost of w to true
                    activate
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
            return "none"
            """ : """
            tell application id "com.googlecode.iterm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      -- The tab and pane first, the window last: bringing a window forward renumbers the
                      -- windows, and "w", "t" and "s" would then point at a different one.
                      set wid to id of w
                      tell t to select
                      tell s to select
                      select (first window whose id is wid)
                      activate
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return "none"
            """
        return script(source) == "ok"
    }
    /// The terminal device of the tab that is in front right now, or nil.
    static func frontTTY(_ kind: String) -> String? {
        let out = script(kind == "terminal"
            ? "tell application \"Terminal\" to return tty of selected tab of front window"
            : "tell application id \"com.googlecode.iterm2\" to return tty of current session of current window")
        return out.hasPrefix("/dev/") ? out : nil
    }
    /// Open a new tab or window in a folder and run a command there. The folder and command are passed as
    /// arguments to the script, never pasted into it, so nothing in a folder name can be run as script.
    static func run(_ kind: String, in cwd: String, command: String) {
        let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let line = "cd \(quoted) && \(command)"
        let source = kind == "terminal"
            ? "on run argv\n tell application \"Terminal\"\n activate\n do script (item 1 of argv)\n end tell\nend run"
            : "on run argv\n tell application id \"com.googlecode.iterm2\"\n activate\n if (count of windows) is 0 then\n create window with default profile\n else\n tell current window to create tab with default profile\n end if\n tell current session of current window to write text (item 1 of argv)\n end tell\nend run"
        let out = Codex.shell("/usr/bin/osascript", ["-e", source, line])
        dbg("terminal run -> \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}

/// What the beacon beside the notch shows: the orb and a word, on a black tab that reads as part of the notch.
/// The word is needed: a bare green dot beside the camera is what macOS shows when the camera is recording.
struct Beacon: View {
    @ObservedObject var model: Model
    var clicked: () -> Void = {}
    @AppStorage("showBeacon") private var wanted = true
    @AppStorage("beaconShows") private var shows = "orb"
    /// What goes beside the orb: the words, and the number that follows them, for a way of showing ("name", "state" or
    /// "orb"). Nil when nothing is going on and nothing shows.
    static func label(sessions: [Session], spotlight: Session?, shows: String) -> (text: String, count: String)? {
        guard let s = spotlight else { return nil }
        let more = sessions.filter { $0.rank == s.rank }.count - 1
        let text = shows == "state" ? ["needs you", "finished", "working"][min(s.rank, 2)] : shows == "orb" ? "" : short(s.title)
        return (text, more > 0 ? (shows == "orb" ? "\(more + 1)" : "+\(more)") : "")
    }
    /// The first few words of a name: at most 16 characters, cut at a word where it can be.
    static func short(_ title: String) -> String {
        let limit = 16
        guard title.count > limit else { return title }
        var cut = String(title.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= 8 { cut = String(cut[..<space]) }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
    var body: some View {
        ZStack(alignment: .trailing) {
            // It stays put while the panel is open: the panel opens over it (its black top covers the tab), and is
            // simply there again as the panel closes. Tucking it away and growing it back each time was busywork.
            if wanted, let s = model.spotlight {
                let more = model.sessions.filter { $0.rank == s.rank }.count - 1   // others in the same state
                HStack(spacing: 6) {
                    Group {
                        if s.rank == 2 { Orb(tint: PortalMark.working) }
                        else if s.rank == 0 { Orb(spinning: false) }
                        else { Orb(spinning: false, tint: PortalMark.done, glow: 0.6) }
                    }
                    .frame(width: 12, height: 12)
                    // The orb's colour already says the state, so the words say which session it is: the start of its
                    // name. Kept short, because this sits over the menu bar. The state word, or nothing, is a setting.
                    let l = Self.label(sessions: model.sessions, spotlight: s, shows: shows) ?? ("", "")
                    if !l.text.isEmpty {
                        Text(l.text).font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(shows == "state" ? (s.rank == 0 ? PortalMark.amber : s.rank == 1 ? PortalMark.done : Color.white.opacity(0.75)) : Color.white.opacity(0.82))
                            .fixedSize()
                    }
                    // Only one session fits here, so say when others are in the same state: "+2", or the total with the orb alone.
                    if !l.count.isEmpty {
                        Text(l.count).font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.5)).fixedSize().padding(.leading, -1)
                    }
                }
                // The black runs right across the notch to its far edge, the way notch apps usually draw their closed state: one
                // black shape of our own, exactly the notch's height, lying over the real notch. So the bottom edge you
                // see is a single drawn line from the tab's left end to the notch's right end, with nothing to line up,
                // and the notch's own rounded corner is the one that shows at the right. On a Mac with no notch it is a
                // small black tab hanging from the top of the screen, rounded on both sides.
                .padding(.leading, 12 + TabShape.flare).padding(.trailing, 9 + (model.beaconNotch > 0 ? model.beaconNotch : 4))
                .frame(maxHeight: .infinity)
                .background(TabShape(far: model.beaconNotch > 0 ? 12 : 10).fill(.black))
                .contentShape(Rectangle())
                
                .onTapGesture(perform: clicked)
                .help((s.rank == 1 ? "Click to clear" : "Click to see your sessions") + (more > 0 ? " · \(more) more \(["need you", "finished", "working"][min(s.rank, 2)])" : ""))
                // It grows out of the notch sideways and goes back into it, instead of fading in and out. The part
                // over the notch is black on black, so at the start it is simply the notch, which then widens.
                .transition(.modifier(active: OutOfNotch(shown: 0, notch: model.beaconNotch), identity: OutOfNotch(shown: 1, notch: model.beaconNotch)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        // Not shown at all while the panel is open: the panel already says the same thing, and macOS can briefly draw
        // either window in front of the other (swiping between desktops, for one). It is simply back as the panel closes,
        // with no fade or slide.
        .opacity(model.open ? 0 : 1)
        .transaction(value: model.open) { $0.animation = nil }
        .animation(.spring(response: 0.42, dampingFraction: 0.92), value: model.spotlight?.rank)
        .animation(.spring(response: 0.42, dampingFraction: 0.92), value: model.spotlight?.id)
    }
}

// ── hooks: the supported way to be told what a session is doing ──
//
// When turned on in settings, a tiny script is registered with Claude Code (and Codex) as a hook. The tool runs it
// on each event that matters and the script writes the event to a file in ~/.codehatch/live. The app reads those
// files. This is the documented interface, where the status files the app reads otherwise are an internal detail
// that could change. The two are combined: whichever spoke most recently about a session is believed, so a session
// that was already running before the hooks were added, or an event hooks do not report (a turn stopped with
// Escape), is still shown correctly.
enum Hooks {
    static let marker = "codehatch-hook.sh"
    /// For testing the install and removal against a copy of the settings, never the real ones.
    static var homeOverride: URL?
    static var home: URL { homeOverride ?? Loader.home }
    static var folder: URL { home.appendingPathComponent(".codehatch") }
    static var live: URL { folder.appendingPathComponent("live") }
    static var script: URL { folder.appendingPathComponent(marker) }
    static var on: Bool { Prefs.bool("liveUpdates") }

    struct Event { let tool: String, name: String, pid: Int32, at: Double, sessionId: String?, cwd: String?, kind: String? }

    /// The latest event of every session. Files for sessions that have ended, or that nothing has written to for
    /// a day, are removed.
    static func read() -> [Event] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: live, includingPropertiesForKeys: nil) else { return [] }
        let now = Date().timeIntervalSince1970
        var out: [Event] = []
        for f in files where f.pathExtension == "json" && !f.lastPathComponent.hasPrefix(".") {
            guard let data = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tool = o["tool"] as? String, let name = o["event"] as? String else { continue }
            let at = (o["at"] as? Double) ?? 0
            if name == "SessionEnd" || now - at > 86_400 { try? FileManager.default.removeItem(at: f); continue }
            func text(_ k: String) -> String? { (o[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            out.append(Event(tool: tool, name: name, pid: Int32((o["pid"] as? Int) ?? 0), at: at, sessionId: text("session_id"), cwd: text("cwd"), kind: text("kind")))
        }
        return out
    }

    /// What an event says about its session: working, waiting on you, or stopped. Nil for events that say nothing.
    static func meaning(_ e: Event) -> (status: String, waitingFor: String?)? {
        switch e.name {
        case "SessionStart", "Stop", "Interrupt": return ("idle", nil)
        case "UserPromptSubmit", "PostToolUse", "PreToolUse": return ("busy", nil)
        case "PermissionRequest": return ("waiting", "permission")
        case "Notification":
            switch e.kind ?? "" {
            case "permission_prompt": return ("waiting", "permission")
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": return ("waiting", "your answer")
            case "idle_prompt": return ("idle", nil)
            default: return nil
            }
        default: return nil
        }
    }

    /// When each session's state last changed according to hooks. A working session reports many events; only a
    /// change of state, or a new prompt, counts as news.
    static var changed: [String: (status: String, at: Double)] = [:]

    /// Lay what the hooks report over the sessions found by other means, and add any that only hooks know about.
    static func overlay(_ sessions: inout [Session]) {
        guard on else { return }
        for e in read() {
            guard let m = meaning(e) else { continue }
            let key = e.sessionId.map { e.tool == "codex" ? "codex-" + $0 : $0 } ?? "\(e.tool)-\(e.pid)"
            if changed[key]?.status != m.status || e.name == "UserPromptSubmit" { changed[key] = (m.status, e.at) }
            let at = (changed[key]?.at ?? e.at) * 1000
            if let i = sessions.firstIndex(where: { $0.id == key || ($0.pid == e.pid && $0.tool == e.tool) }) {
                // For Claude Code, believe whichever spoke last: its status file also records a turn stopped with
                // Escape, which no hook reports. Hook times are whole seconds, so allow a second's grace.
                // For Codex the hook is always believed. The only other clue is when its log was last written, and
                // Codex writes to that all the time, so it says nothing about which is newer. Codex also reports
                // an interrupted turn through a hook, so there is no gap to cover.
                guard e.tool == "codex" || at + 1000 >= sessions[i].updatedAt else { continue }
                let old = sessions[i]
                var s = Session(id: old.id, pid: old.pid, cwd: old.cwd, status: m.status, updatedAt: max(at, m.status == old.status ? old.updatedAt : at), title: old.title)
                s.startedAt = old.startedAt; s.tool = old.tool; s.inPanel = old.inPanel; s.recap = old.recap; s.lastAsked = old.lastAsked; s.lastReply = old.lastReply; s.replyIsNewer = old.replyIsNewer
                s.branch = old.branch; s.empty = old.empty; s.waitingFor = m.waitingFor
                sessions[i] = s
            } else if e.tool == "claude", let sid = e.sessionId, !sid.hasPrefix("pid-"), let cwd = e.cwd, e.pid > 1, kill(e.pid, 0) == 0 {
                // Known only from hooks: the status file is missing. Build the session from the event.
                let found = Loader.title(for: sid, cwd: cwd)
                var s = Session(id: sid, pid: e.pid, cwd: cwd, status: m.status, updatedAt: at, title: found ?? "New session")
                s.empty = found == nil; s.waitingFor = m.waitingFor
                let ex = Loader.extras(for: sid, cwd: cwd); s.recap = ex.recap; s.branch = ex.branch; s.lastAsked = ex.asked; s.lastReply = ex.reply; s.replyIsNewer = ex.newer
                sessions.append(s)
            }
        }
        sessions.sort { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }

    // ── turning it on and off ──

    static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Notification", "Stop", "SessionEnd"]
    static var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }

    /// Put the script in place. It lives outside the app so the hooks keep working when the app is moved or updated.
    static func placeScript() -> Bool {
        guard let src = Bundle.main.url(forResource: "codehatch-hook", withExtension: "sh") else { dbg("hooks: script missing from the app"); return false }
        try? FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: script)
        do { try FileManager.default.copyItem(at: src, to: script); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path) }
        catch { dbg("hooks: could not place script: \(error)"); return false }
        return true
    }
    static func command(_ tool: String, _ event: String) -> String { "'\(script.path)' \(tool) \(event)" }

    /// Read a JSON settings file as a dictionary, keeping everything in it. A file that is not valid JSON is left alone.
    static func readJSON(_ url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return o
    }
    static func writeJSON(_ o: [String: Any], to url: URL) -> Bool {
        // A copy of the file as it was, made once, before the first change.
        let backup = url.appendingPathExtension("before-codehatch")
        if FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: url, to: backup) }
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }
    /// The same settings with codehatch's entries taken out, and nothing else touched.
    static func without(_ settings: [String: Any]) -> [String: Any] {
        var out = settings
        guard var hooks = out["hooks"] as? [String: Any] else { return out }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let mine = handlers.filter { !(($0["command"] as? String) ?? "").contains(marker) }
                if mine.isEmpty { return nil }
                var g = group; g["hooks"] = mine; return g
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { out.removeValue(forKey: "hooks") } else { out["hooks"] = hooks }
        return out
    }
    static func installClaude() -> Bool {
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path) else { return true }   // Claude Code is not on this Mac
        guard let current = readJSON(claudeSettings) else { dbg("hooks: Claude Code settings are not valid JSON; left alone"); return false }
        var settings = without(current)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in claudeEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": command("claude", event), "timeout": 5]]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return writeJSON(settings, to: claudeSettings)
    }
    static func removeClaude() -> Bool {
        guard FileManager.default.fileExists(atPath: claudeSettings.path), let current = readJSON(claudeSettings) else { return true }
        return writeJSON(without(current), to: claudeSettings)
    }

    // Codex keeps its hooks in a file of their own, in the same shape as Claude Code's. It will not run a hook
    // until you have looked at it and trusted it, by typing /hooks in a Codex session.
    static let codexEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SessionEnd"]
    static var codexHooks: URL { home.appendingPathComponent(".codex/hooks.json") }
    static var hasCodex: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path) }
    static func installCodex() -> Bool {
        guard hasCodex else { return true }
        guard let current = readJSON(codexHooks) else { dbg("hooks: Codex hooks file is not valid JSON; left alone"); return false }
        var file = without(current)
        var hooks = file["hooks"] as? [String: Any] ?? [:]
        for event in codexEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": command("codex", event), "timeout": event == "SessionEnd" || event == "Interrupt" ? 3 : 5]]])
            hooks[event] = groups
        }
        file["hooks"] = hooks
        return writeJSON(file, to: codexHooks)
    }
    static func removeCodex() -> Bool {
        guard FileManager.default.fileExists(atPath: codexHooks.path), let current = readJSON(codexHooks) else { return true }
        let cleaned = without(current)
        // If the file held nothing but codehatch's hooks, take the file away again.
        if cleaned.isEmpty { return (try? FileManager.default.removeItem(at: codexHooks)) != nil }
        return writeJSON(cleaned, to: codexHooks)
    }

    /// Turn live updates on or off everywhere. Returns a line to show the user if something could not be done.
    static func set(_ wanted: Bool) -> String? {
        if wanted {
            guard placeScript() else { return "Could not put the hook script in place." }
            guard installClaude() else { return "Could not change Claude Code's settings. They were left as they were." }
            guard installCodex() else { return "Claude Code is set up, but Codex's hooks file could not be changed." }
            return nil
        }
        let a = removeClaude(), b = removeCodex()
        try? FileManager.default.removeItem(at: live)
        return a && b ? nil : "Some hook entries could not be removed."
    }
}

/// Lays its pieces out left to right and starts a new line when the next one will not fit.
struct Wrap: Layout {
    var spacing: CGFloat = 6
    func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]], x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > width, !rows[rows.count - 1].isEmpty { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, size)); x += size.width + spacing
        }
        return rows.map { $0.map { (index: $0.0, size: $0.1) } }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600, lines = rows(subviews, width: width)
        let height = lines.map { $0.map(\.size.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            let tall = line.map(\.size.height).max() ?? 0
            for item in line {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (tall - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += tall + spacing
        }
    }
}

/// Every choice in the settings window, with its default. Read straight from here wherever it matters.
/// The editor helper: a small extension for Cursor, VS Code and editors built on it. It lets codehatch bring the right
/// terminal tab forward and reopen a session in the right project. It travels inside the app and is installed with
/// the editor's own command-line tool, the same way "Install from VSIX" does.
enum Helper {
    static let id = "codehatch.codehatch-helper"
    static let editors: [(id: String, label: String, app: String, cli: String, extensions: String)] = [
        ("cursor", "Cursor", "/Applications/Cursor.app", "Contents/Resources/app/bin/cursor", ".cursor/extensions"),
        ("vscode", "VS Code", "/Applications/Visual Studio Code.app", "Contents/Resources/app/bin/code", ".vscode/extensions"),
        ("windsurf", "Windsurf", "/Applications/Windsurf.app", "Contents/Resources/app/bin/windsurf", ".windsurf/extensions"),
        ("vscodium", "VSCodium", "/Applications/VSCodium.app", "Contents/Resources/app/bin/codium", ".vscode-oss/extensions"),
    ]
    /// The editors on this Mac.
    static var present: [(id: String, label: String, app: String, cli: String, extensions: String)] {
        editors.filter { FileManager.default.fileExists(atPath: $0.app + "/" + $0.cli) }
    }
    /// The helper as packaged inside the app.
    static var package: URL? { Bundle.main.urls(forResourcesWithExtension: "vsix", subdirectory: nil)?.sorted { $0.lastPathComponent < $1.lastPathComponent }.last }
    /// For the tests: install into this folder instead of the editor's own.
    static var folderOverride: String? { ProcessInfo.processInfo.environment["CODEHATCH_HELPER_DIR"] }
    static func folder(_ e: (id: String, label: String, app: String, cli: String, extensions: String)) -> URL {
        folderOverride.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(e.extensions)
    }
    static func installed(_ e: (id: String, label: String, app: String, cli: String, extensions: String)) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder(e).path)) ?? []).contains { $0.lowercased().hasPrefix(id + "-") }
    }
    /// Install it. Returns nil when it is in place afterwards, or a sentence saying what went wrong.
    static func install(_ e: (id: String, label: String, app: String, cli: String, extensions: String)) -> String? {
        guard let package else { return "The helper is missing from this copy of codehatch." }
        var args = ["--install-extension", package.path, "--force"]
        if let folderOverride { args += ["--extensions-dir", folderOverride] }
        let out = Codex.shell(e.app + "/" + e.cli, args)
        dbg("helper: install in \(e.label): \(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(120))")
        return installed(e) ? nil : "\(e.label) did not accept the helper."
    }
}

/// Everything codehatch adds outside itself, in one place: the hooks and the editor helper. Run once from the welcome
/// window, and again from settings whenever asked.
enum Setup {
    /// Each thing set up and how it went: nil is fine, otherwise what went wrong.
    static func run(hooks: Bool, editors: [String]) -> [(what: String, problem: String?)] {
        var out: [(what: String, problem: String?)] = []
        if hooks {
            let problem = Hooks.set(true)
            if problem == nil { UserDefaults.standard.set(true, forKey: "liveUpdates") }
            out.append(("Live updates", problem))
        }
        for e in Helper.editors where editors.contains(e.id) { out.append(("Helper for " + e.label, Helper.install(e))) }
        return out
    }
    /// Whether the welcome window should appear: not yet shown, and there is something it could set up.
    static var wanted: Bool { !Prefs.bool("didSetup") && !Demo.on && ProcessInfo.processInfo.environment["CODEHATCH_HOME"] == nil }
}

/// The welcome window: what codehatch would like to add, said plainly, with one button to add it.
struct SetupView: View {
    var done: () -> Void
    @State private var hooks = true
    @State private var atLogin = true
    @State private var editors: Set<String> = Set(Helper.present.map(\.id))
    @State private var results: [(what: String, problem: String?)]? = nil
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The mark on a plain black square, drawn here rather than taken from the app icon: macOS 26 gives app icons
            // a glassy light rim, which looked like a white border at this size.
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black)
                if let url = Bundle.main.url(forResource: "portal", withExtension: "png"), let mark = NSImage(contentsOf: url) {
                    Image(nsImage: mark).resizable().interpolation(.high).frame(width: 28, height: 28)
                }
            }
            .frame(width: 52, height: 52)
            Text("Set up codehatch").font(.system(size: 20, weight: .semibold))
            Text("codehatch works best with two small additions. Both are plain files you can read, both can be removed in settings, and neither sends anything anywhere.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let results {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: r.problem == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(r.problem == nil ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.what)
                                if let p = r.problem { Text(p).font(.callout).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if Hooks.hasCodex && hooks { Text("Codex will not run the hooks until you type /hooks in a Codex session and trust them.").font(.callout).foregroundStyle(.secondary).padding(.top, 2) }
                    if !editors.isEmpty { Text("The first time you jump to a session, your editor asks once whether the helper may open the link. Say yes.").font(.callout).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 4)
                HStack { Spacer(); Button("Done") { done() }.keyboardShortcut(.defaultAction) }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $hooks) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Live updates").font(.system(size: 13, weight: .medium))
                            Text("Adds a small script to Claude Code" + (Hooks.hasCodex ? " and Codex" : "") + " so they tell codehatch the moment a session starts, stops or needs you. It records the event only, never your prompts. A copy of each settings file is saved first.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Toggle(isOn: $atLogin) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open at login").font(.system(size: 13, weight: .medium))
                            Text("So it is there after you restart your Mac.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Helper.present, id: \.id) { e in
                        Toggle(isOn: Binding(get: { editors.contains(e.id) }, set: { on in if on { editors.insert(e.id) } else { editors.remove(e.id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Helper for \(e.label)" + (Helper.installed(e) ? " (already installed)" : "")).font(.system(size: 13, weight: .medium))
                                Text("A small extension that lets codehatch land on the exact terminal tab in \(e.label) and reopen a closed session in the right project.")
                                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if Helper.present.isEmpty { Text("No editor built on VS Code was found, so there is no helper to install. Terminal and iTerm2 need none.").font(.callout).foregroundStyle(.secondary) }
                }
                .toggleStyle(.checkbox)
                HStack {
                    Button("Not now") { done() }
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button("Set up") {
                        working = true
                        let wantHooks = hooks, wantEditors = Array(editors), wantLogin = atLogin
                        DispatchQueue.global().async {
                            var r = Setup.run(hooks: wantHooks, editors: wantEditors)
                            if wantLogin { r.append(("Open at login", LoginItem.set(true))) }
                            DispatchQueue.main.async { results = r; working = false }
                        }
                    }
                    .keyboardShortcut(.defaultAction).disabled(working || (!hooks && !atLogin && editors.isEmpty))
                }
            }
        }
        .padding(22).frame(width: 470)
    }
}

/// Draws a part of the interface to a picture without showing it, using the sample sessions. The tests use it to
/// check that each layout and each look actually draws, at a sensible size, and that light is light and dark is dark.
enum Render {
    @MainActor static func run(_ what: String, look: String, to path: String) {
        Demo.forced = true   // sample sessions for this run only; nothing is written to the saved settings
        let model = Model()
        model.sessions = Demo.sessions(); model.recent = Demo.closed(); model.currentId = model.sessions.first?.id; model.open = true
        model.barHeight = 32; model.notchWidth = 190
        let light = look == "light"
        let size: CGSize, view: AnyView
        switch what {
        case "panel": size = CGSize(width: RootView.openWidth, height: RootView.openHeight); view = AnyView(RootView(model: model, app: nil).environmentObject(PointerTracker.panel))
        // A Mac with no notch (a desktop Mac, an external display): the panel hangs from the top centre of the screen.
        case "panel-desktop": model.notchWidth = 0; model.barHeight = 24; size = CGSize(width: RootView.openWidth, height: RootView.openHeight); view = AnyView(RootView(model: model, app: nil).environmentObject(PointerTracker.panel))
        case "settings": size = CGSize(width: 520, height: 560); view = AnyView(SettingsView(app: nil))
        case "setup": size = CGSize(width: 470, height: 480); view = AnyView(SetupView(done: {}))
        default: size = CGSize(width: 1180, height: 640); view = AnyView(RootView(model: model, app: nil, detached: true).environmentObject(PointerTracker.window))
        }
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, light ? .light : .dark))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)   // never ordered front
        window.appearance = host.appearance; window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))   // let lazy lists and images settle
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("{}"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        // How light the picture is on average (0 black, 1 white), and how many clearly different shades it holds.
        var sum = 0.0, n = 0.0, shades = Set<Int>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 6) { for x in stride(from: 0, to: rep.pixelsWide, by: 6) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let a = Double(c.alphaComponent), l = (0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent))
            // Where the picture is see-through (the glass), count what would be behind it in that look: white or black.
            let seen = l * a + (light ? 1.0 : 0.0) * (1 - a)
            sum += seen; n += 1; shades.insert(Int(seen * 24))
        } }
        let out: [String: Any] = ["width": rep.pixelsWide, "height": rep.pixelsHigh, "lightness": n > 0 ? sum / n : 0, "shades": shades.count]
        if let data = try? JSONSerialization.data(withJSONObject: out) { FileHandle.standardOutput.write(data); print("") }
    }
}

/// Opening codehatch when you log in, through the Mac's own login items (System Settings › General › Login Items).
enum LoginItem {
    static var on: Bool { SMAppService.mainApp.status == .enabled }
    /// Returns nil when it worked, or what went wrong.
    @discardableResult static func set(_ wanted: Bool) -> String? {
        do {
            if wanted { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
            else if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            dbg("login item: \(error)")
            return "macOS would not change this. You can add codehatch in System Settings › General › Login Items."
        }
    }
}

enum Prefs {
    static let defaults: [String: Any] = [
        "openOnHover": true, "hotkey": "opt-space", "showLastMessage": true, "showRecent": true, "recentDays": 14,
        "widgetOnTop": false, "confirmClose": true, "reopenIn": "auto", "demoMode": false, "hiddenRepos": "", "notchOrder": "recent", "liveUpdates": false, "showBeacon": true, "beaconShows": "orb", "windowLook": "system",
        "showMenuIcon": true, "widgetLayout": "cards", "widgetGroup": "state", "widgetFilter": "all", "didSetup": false,
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
    /// Set by the drawing tests, which want sample sessions without changing anyone's saved setting.
    static var forced = false
    /// The sample session you last went to, which then counts as the one you are in.
    static var here: String?
    static var on: Bool { forced || Prefs.bool("demoMode") }
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
    // Recently closed sample sessions: id, repo, title, seconds since, branch, what you last asked, where it got to.
    static let closedRows: [(String, String, String, Double, String, String, String)] = [
        ("3f2a9c1e-7b4d-4e8a-9c21-5d6e7f8a9b01", "storefront", "Fix the cart badge count", 2_400, "fix/cart-badge", "ship it",
         "The badge now counts items rather than lines, and updates as soon as something is added. Merged."),
        ("8b1c2d3e-4f5a-4b6c-8d7e-9f0a1b2c3d02", "api-server", "Webhook retries with backoff", 9_000, "feature/webhook-retries", "add a test for the fifth retry",
         "Failed webhooks are retried up to five times, waiting longer each time. The test for the fifth retry is the last thing open."),
        ("c4d5e6f7-a8b9-4c0d-9e1f-2a3b4c5d6e03", "ios-app", "Dark mode for settings", 18_000, "feature/settings-dark-mode", "the toggles are too dim",
         "Settings follow the system's dark mode. The toggles are brighter; the last thing to check is the colour of the section headers."),
        ("d7e8f9a0-b1c2-4d3e-8f4a-5b6c7d8e9f04", "storefront", "Faster product images", 30_000, "perf/product-images", "use the smaller sizes on phones",
         "Product images load in the size each screen needs. Phones now download about a third as much."),
        ("e1f2a3b4-c5d6-4e7f-9a8b-0c1d2e3f4a05", "api-server", "Rotate the signing keys", 64_000, "chore/rotate-keys", "keep the old key valid for a day",
         "New keys are in use. The old one is still accepted until tomorrow, then it can be removed."),
        ("f5a6b7c8-d9e0-4f1a-8b2c-3d4e5f6a7b06", "docs-site", "Broken links in the API reference", 150_000, "fix/api-ref-links", "run the link checker again",
         "Fixed 14 broken links. The link checker now runs on every change, so new ones are caught before they go live."),
        ("a9b0c1d2-e3f4-4a5b-9c6d-7e8f9a0b1c07", "ios-app", "Pull to refresh on the orders screen", 240_000, "feature/orders-refresh", "add the little haptic when it lets go",
         "Pulling down on the orders screen refreshes it, with a light tap of feedback as it lets go."),
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
            // Its folder: the matching made-up project in ~/codehatch-demo if there is one, so resuming it for a recording
            // lands somewhere real.
            let demo = NSHomeDirectory() + "/codehatch-demo/" + r.1
            var s = Session(id: r.0, pid: 0, cwd: FileManager.default.fileExists(atPath: demo) ? demo : "/Projects/" + r.1, status: "closed", updatedAt: (now - r.3) * 1000, title: r.2)
            s.branch = r.4; s.lastAsked = r.5; s.recap = r.6
            return s
        }
    }
}

struct SettingsView: View {
    weak var app: AppDelegate?
    @AppStorage("openOnHover") var openOnHover = true
    @AppStorage("windowLook") var windowLook = "system"
    @AppStorage("showBeacon") var showBeacon = true
    @AppStorage("beaconShows") var beaconShows = "orb"
    @State private var helperNote: [String: String] = [:]
    @State private var loginOn = LoginItem.on
    @AppStorage("showMenuIcon") var showMenuIcon = true
    @State private var loginNote: String?
    @AppStorage("hotkey") var hotkey = "opt-space"
    @AppStorage("showLastMessage") var showLastMessage = true
    @AppStorage("showRecent") var showRecent = true
    @AppStorage("recentDays") var recentDays = 14
    @AppStorage("widgetOnTop") var widgetOnTop = false
    @AppStorage("confirmClose") var confirmClose = true
    @AppStorage("reopenIn") var reopenIn = "auto"
    @AppStorage("demoMode") var demoMode = false
    @AppStorage("hiddenRepos") var hiddenRepos = ""
    @AppStorage("notchOrder") var notchOrder = "recent"
    @AppStorage("liveUpdates") var liveUpdates = false
    @State private var hookProblem: String?
    @State private var page = 0
    var body: some View {
        // Three pages, chosen at the top, so the window stays a sensible height.
        VStack(spacing: 0) {
            Picker("", selection: $page) { Text("General").tag(0); Text("Sessions").tag(1); Text("Privacy").tag(2) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300).padding(.top, 14).padding(.bottom, 4)
            if page == 0 { Form {
            Section("Opening the panel") {
                Toggle("Open when the pointer is pushed into the notch", isOn: $openOnHover)
                Toggle("Show codehatch in the menu bar", isOn: $showMenuIcon)
                Toggle("Open at login", isOn: Binding(get: { loginOn }, set: { want in loginNote = LoginItem.set(want); loginOn = LoginItem.on }))
                if let loginNote { Text(loginNote).font(.callout).foregroundStyle(.secondary) }
                Toggle("Show the current status beside the notch", isOn: $showBeacon)
                Picker("Next to the orb, show", selection: $beaconShows) { Text("Nothing, just the orb").tag("orb"); Text("The session's name").tag("name"); Text("The state").tag("state") }.disabled(!showBeacon)
                Picker("Keyboard shortcut", selection: $hotkey) { ForEach(Prefs.hotkeys, id: \.id) { Text($0.label).tag($0.id) } }
            }
            Section {
                Picker("Order the notch list by", selection: $notchOrder) {
                    Text("Most recent").tag("recent")
                    Text("Repo").tag("repo")
                }
            } header: { Text("Order") } footer: {
                Text(notchOrder == "repo" ? "Sessions are grouped under their repo. Repos are in alphabetical order and stay put." : "One list, with the session you touched last on top.")
            }
            Section {
                Toggle("Show the last message under each session", isOn: $showLastMessage)
            } header: { Text("What each session shows") } footer: {
                Text("Whichever came last: what you said, or the reply.")
            }
            Section("Stay-on-screen window") {
                Toggle("Keep it above other windows", isOn: $widgetOnTop)
                Picker("Appearance", selection: $windowLook) { Text("Match the system").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
            }
            Section {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { app?.updater.updater.automaticallyChecksForUpdates ?? true },
                    set: { app?.updater.updater.automaticallyChecksForUpdates = $0 }))
                HStack {
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").foregroundStyle(.secondary)
                    Spacer()
                    Button("Check now") { app?.updater.checkForUpdates(nil) }
                }
            } header: { Text("Updates") } footer: {
                Text("Claude Code and Codex change how they work from time to time. Updates keep codehatch reading them correctly.")
            }
            Section {
                ForEach(Helper.present, id: \.id) { e in
                    HStack {
                        Text(e.label)
                        Spacer()
                        Text(helperNote[e.id] ?? (Helper.installed(e) ? "Installed" : "Not installed")).foregroundStyle(.secondary)
                        Button(Helper.installed(e) ? "Reinstall" : "Install") {
                            helperNote[e.id] = "Installing…"
                            DispatchQueue.global().async { let problem = Helper.install(e); DispatchQueue.main.async { helperNote[e.id] = problem ?? "Installed" } }
                        }
                    }
                }
                if Helper.present.isEmpty { Text("No editor built on VS Code was found.").foregroundStyle(.secondary) }
                Button("Show the welcome window again") { app?.showSetup() }
            } header: { Text("Editor helper") } footer: {
                Text("A small extension that lets codehatch land on the exact terminal tab in your editor and reopen a closed session in the right project. Terminal and iTerm2 need none.")
            }
            Section {
                HStack {
                    Text("codehatch has no Dock icon, so this is where you quit it. Your sessions keep running.").foregroundStyle(.secondary).font(.callout)
                    Spacer()
                    Button("Quit codehatch") { NSApp.terminate(nil) }
                }
            }
            }
            .formStyle(.grouped) }
            if page == 1 { Form {
            Section("Closed sessions") {
                Toggle("List recently closed sessions so they can be resumed", isOn: $showRecent)
                Picker("Go back", selection: $recentDays) {
                    Text("1 day").tag(1); Text("3 days").tag(3); Text("7 days").tag(7); Text("14 days").tag(14); Text("30 days").tag(30)
                }.disabled(!showRecent)
                Picker("Resume them in", selection: $reopenIn) {
                    Text("Where I last was").tag("auto")
                    ForEach(Prefs.editors.filter { FileManager.default.fileExists(atPath: $0.app) }, id: \.id) { Text($0.label).tag($0.id) }
                    Text("Terminal").tag("terminal")
                    if FileManager.default.fileExists(atPath: Terminals.paths["iterm"]!) { Text("iTerm2").tag("iterm") }
                }.disabled(!showRecent)
                Toggle("Ask before closing a session that is working or waiting on you", isOn: $confirmClose)
            }
            Section {
                Toggle("Use hooks for live updates", isOn: Binding(get: { liveUpdates }, set: { wanted in
                    hookProblem = Hooks.set(wanted)
                    liveUpdates = hookProblem == nil ? wanted : liveUpdates
                    app?.refresh()
                }))
                if let hookProblem { Text(hookProblem).foregroundStyle(.red) }
            } header: { Text("Live updates") } footer: {
                Text(liveUpdates
                     ? "Hooks are registered with Claude Code" + (Hooks.hasCodex ? " and Codex. Codex will not run them until you type /hooks in a Codex session and trust them." : ".") + " They apply to sessions started from now on. Turning this off removes every entry."
                     : "Registers a small script with Claude Code" + (Hooks.hasCodex ? " and Codex" : "") + " so they tell codehatch when a session starts, works, needs you or finishes. It only records the event; it cannot change or block a session. A copy of each settings file is kept before the first change.")
            }
            }
            .formStyle(.grouped) }
            if page == 2 { Form {
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
            .formStyle(.grouped) }
            Spacer(minLength: 0)
        }
        .frame(width: 520, height: 560)
        .onChange(of: hotkey) { _, _ in app?.registerHotKey() }
        .onChange(of: widgetOnTop) { _, on in app?.widget?.level = on ? .floating : .normal }
        .onChange(of: windowLook) { _, _ in app?.applyWindowLook() }
        .onChange(of: showMenuIcon) { _, _ in app?.setUpStatusItem() }
        .onChange(of: recentDays) { _, _ in Loader.recentCache.at = 0; app?.refresh() }
        .onChange(of: showRecent) { _, _ in app?.refresh() }
        .onChange(of: demoMode) { _, _ in Demo.hidden = []; app?.refresh() }
        .onChange(of: hiddenRepos) { _, _ in app?.refresh() }
        .onChange(of: notchOrder) { _, _ in app?.refresh() }
    }
}

// ── the interface ──
struct RootView: View {
    @ObservedObject var model: Model
    weak var app: AppDelegate?
    var detached = false   // true for the stay-on-screen window, false for the panel under the notch
    @Environment(\.colorScheme) private var scheme
    /// The stay-on-screen window can be light; the panel under the notch is always dark, to join the notch.
    var lightLook: Bool { detached && scheme == .light }
    /// The colour of words and lines: white on dark, black on light.
    var ink: Color { lightLook ? .black : .white }
    /// The colour behind them.
    var paper: Color { lightLook ? .white : .black }
    var lav: Color { lightLook ? Color(red: 0.80, green: 0.42, blue: 0.02) : PortalMark.amber }
    var grn: Color { lightLook ? Color(red: 0.10, green: 0.58, blue: 0.32) : PortalMark.done }
    @FocusState private var searchFocused: Bool
    @State private var settled = false                // true a moment after the window first appears; nothing animates before
    @AppStorage("showLastMessage") private var showLast = true
    @AppStorage("notchOrder") private var notchOrder = "recent"
    private var byRepo: Bool { notchOrder == "repo" }
    /// Where the session you are in sits in the list as now filtered, or -1 (no highlight) if it is not showing.
    private var hereIndex: Int { model.filtered.firstIndex { $0.id == model.currentId } ?? -1 }
    @AppStorage("confirmClose") private var confirmBusy = true
    @State private var copied: String?                // the session whose resume command was just copied
    @State private var overX: String?                 // the row whose x the pointer is on
    static let showX = CommandLine.arguments.contains("--show-x")   // for screenshots: show every row's x
    @State private var confirmClose: String?          // the row whose x has been clicked once and is asking "Close?"
    @State private var showUnused: Set<String> = []   // groups whose never-used sessions are expanded
    @State private var collapsed: Set<String> = []    // groups folded shut
    @State private var openClosed: Set<String> = []   // repos whose recently closed sessions are unfolded; folded to begin with
    @State private var shutInSearch: Set<String> = [] // while searching they start unfolded instead; these are the ones folded by hand
    /// Whether a repo's fold inside "Recently closed" is open. Folded to begin with; while you search, the repos with
    /// matches are open so the results can be seen. Either way a click on the fold's heading flips it.
    func closedFoldOpen(_ name: String) -> Bool { model.query.isEmpty ? openClosed.contains(name) : !shutInSearch.contains(name) }
    @State private var detailId: String?              // the session shown in the detail pane: the one last clicked
    @State private var paneShown = false              // whether the window is wide enough to show the detail pane
    @AppStorage("widgetGroup") private var groupBy = "state"    // repo | state
    @AppStorage("widgetLayout") private var layout = "cards"    // list | cards
    @AppStorage("widgetFilter") private var filter = "all"     // all | active
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
                // Centred in the title bar, clear of the close, minimise and full-screen buttons on the left.
                stats.frame(maxWidth: .infinity).padding(.horizontal, 78).frame(height: 30)
                searchRow
                toolbar(roomy: table)
                Rectangle().fill(ink.opacity(0.08)).frame(height: 1)
                HStack(spacing: 0) {
                    ScrollView {
                        // The group headers scroll with the list. Kept in place they needed a solid fill to hide the rows
                        // passing under them, and a solid fill looked different from the glass around it depending
                        // on whether the window was focused.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groups) { g in
                                Section(header: groupHeader(g)) {
                                    if !collapsed.contains(g.id), g.id == Self.closedGroup {
                                        // Recently closed: one fold per repo, shut to begin with; searching opens them all.
                                        ForEach(repos(in: g.items), id: \.self) { name in
                                            let mine = g.items.filter { $0.project == name }, open = closedFoldOpen(name)
                                            closedRepoHeader(name, count: mine.count, open: open).padding(.leading, 14)
                                            if open {
                                                if layout == "cards" {
                                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 420), spacing: 10)], alignment: .leading, spacing: 10) {
                                                        ForEach(mine) { s in sessionCard(s) }
                                                    }
                                                    .padding(.horizontal, 14).padding(.bottom, 10).padding(.top, 2)
                                                } else {
                                                    ForEach(mine) { s in sessionRow(s, table: table) }
                                                }
                                            }
                                        }
                                    } else if !collapsed.contains(g.id) {
                                        let cards = g.items + (showUnused.contains(g.id) ? g.unused : [])
                                        if layout == "cards", !cards.isEmpty {
                                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 420), spacing: 10)], alignment: .leading, spacing: 10) {
                                                ForEach(cards) { s in sessionCard(s) }
                                            }
                                            .padding(.horizontal, 14).padding(.vertical, 10)
                                        } else if layout != "cards" {
                                            ForEach(g.items) { s in sessionRow(s, table: table) }
                                        }
                                        if !g.unused.isEmpty {
                                            if layout != "cards", showUnused.contains(g.id) { ForEach(g.unused) { s in sessionRow(s, table: table) } }
                                            Text(showUnused.contains(g.id) ? "hide unused" : "\(g.unused.count) opened but never used")
                                                .font(.system(size: 11)).foregroundStyle(ink.opacity(0.3))
                                                .padding(.leading, layout == "cards" ? 16 : 44).padding(.vertical, layout == "cards" ? 8 : 6).frame(maxWidth: .infinity, alignment: .leading)
                                                .contentShape(Rectangle())
                                                .onTapGesture { toggle(&showUnused, g.id) }
                                        }
                                    }
                                }
                            }
                            if groups.isEmpty {
                                Text(model.query.isEmpty ? "Nothing here yet." : "No session matches that.")
                                    .font(.system(size: 12.5)).foregroundStyle(ink.opacity(0.4)).padding(24).frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.bottom, 14)
                        // When a session has activity it glides up to its new place, and the others slide to make room.
                        // Only once the window has settled. On first appearing, the list going from empty to full was itself
                        // "a change", and every row and card flew in from the corner.
                        .animation(settled ? .spring(response: 0.5, dampingFraction: 0.84) : nil, value: groups.flatMap { $0.items.map { $0.id } })
                    }
                    if wide {
                        Rectangle().fill(ink.opacity(0.08)).frame(width: 1)
                        detailPane.frame(width: 380)
                    }
                }
                .onAppear { paneShown = wide }
                .onChange(of: wide) { _, now in paneShown = now }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Which groups are folded is remembered, like the rest of the window's view choices. The first time, recently
        // closed sessions are folded away: they are there to resume from, not to read through every time.
        .onAppear {
            var quiet = Transaction(); quiet.disablesAnimations = true
            withTransaction(quiet) { collapsed = Set(UserDefaults.standard.stringArray(forKey: "widgetFolded") ?? [Self.closedGroup]) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled = true }
        }
        .onChange(of: collapsed) { _, now in UserDefaults.standard.set(Array(now), forKey: "widgetFolded") }
        // Dark enough that the list reads the same whatever is behind the window; the glass shows as a faint tint.
        .background {
            // Glass in both looks. Each has a wash of its own tone over the glass, enough that words stay readable
            // whatever is behind the window and whether or not it is the focused one, and no more than that.
            // The Mac's long-standing blur, not macOS 26's Liquid Glass: Liquid Glass draws itself in over half a
            // second whenever its window appears or changes size, so the window opened bare and the glass then slid
            // in over it. This one is there from the first frame, and looks the same focused or not.
            if lightLook { ZStack { PanelBlur(light: true); Color.white.opacity(0.55) } }
            else { ZStack { PanelBlur(); Color.black.opacity(0.5) } }
        }
        .overlay(alignment: .bottom) { closedToast }
        .ignoresSafeArea()
    }

    func toggle(_ set: inout Set<String>, _ id: String) { if set.contains(id) { set.remove(id) } else { set.insert(id) } }
    func isActive(_ s: Session) -> Bool { !s.empty && (s.rank < 3 || s.seconds < 86_400) }

    static let closedGroup = "Recently closed · click to resume"
    struct SessionGroup: Identifiable { let id: String; let items: [Session]; let unused: [Session] }
    /// The list's contents: search, then the chosen filter, then grouped by repo or by state.
    func sessionGroups() -> [SessionGroup] {
        var rows = model.hits
        if filter == "active" { rows = rows.filter(isActive) }
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
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(ink.opacity(0.45))
            TextField("", text: $model.query, prompt: Text("Search sessions").foregroundStyle(ink.opacity(0.35)))
                .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(ink).tint(ink)
            if detached { lookSwitch }
            gear
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    /// Which sessions to show, and how to group them. Both choices are remembered.
    func toolbar(roomy: Bool) -> some View {
        HStack(spacing: 6) {
            chip("All", model.hits.count, on: filter == "all") { filter = "all" }
            chip("Active", model.hits.filter(isActive).count, on: filter == "active") { filter = "active" }
            Spacer()
            // Named choices, not an icon: nobody guesses that a small grid icon means "there is another layout".
            // In a narrow window the two captions go, and the choices stay.
            if roomy { Text("View").font(.system(size: 11)).foregroundStyle(ink.opacity(0.35)) }
            chip("List", nil, on: layout != "cards") { layout = "list" }
            chip("Cards", nil, on: layout == "cards") { layout = "cards" }
            if roomy { Text("Group by").font(.system(size: 11)).foregroundStyle(ink.opacity(0.35)).padding(.leading, 8) } else { Spacer().frame(width: 4) }
            chip("Repo", nil, on: groupBy == "repo") { groupBy = "repo" }
            chip("State", nil, on: groupBy == "state") { groupBy = "state" }
        }
        .padding(.horizontal, 14).padding(.bottom, 9)
    }
    func chip(_ label: String, _ count: Int?, on: Bool, _ act: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(ink.opacity(on ? 0.95 : 0.55))
            if let count { Text("\(count)").foregroundStyle(ink.opacity(on ? 0.5 : 0.28)).monospacedDigit() }
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(ink.opacity(on ? 0.12 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: act)
    }

    /// A slim bar naming the group, how many are in it and what they are doing. Click to fold it.
    func groupHeader(_ g: SessionGroup) -> some View {
        let all = g.items, doing = [all.filter { $0.rank == 0 }.count, all.filter { $0.rank == 1 }.count, all.filter { $0.rank == 2 }.count]
        let note = groupBy == "state" ? "" : zip(doing, ["needs you", "finished", "working"]).filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        return HStack(spacing: 8) {
            Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(ink.opacity(0.4))
                .rotationEffect(.degrees(collapsed.contains(g.id) ? 0 : 90))
            if groupBy == "repo" && g.id != Self.closedGroup { RepoIcon().stroke(ink.opacity(0.6), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)).frame(width: 11, height: 11) }
            Text(g.id).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.opacity(0.82))
            Text("\(all.count)").font(.system(size: 11.5)).foregroundStyle(ink.opacity(0.32)).monospacedDigit()
            if !note.isEmpty { Text(note).font(.system(size: 11)).foregroundStyle(ink.opacity(0.5)) }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        // A faint wash of the ink, fainter than a highlighted row, so the two never read as the same thing.
        .background(ink.opacity(0.04))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { toggle(&collapsed, g.id) } }
    }

    @ViewBuilder func orb(_ s: Session) -> some View {
        if s.rank == 2 { Orb(tint: PortalMark.working, light: lightLook) }
        else if s.rank == 0 { Orb(spinning: false, light: lightLook) }
        else if s.rank == 1 { Orb(spinning: false, tint: PortalMark.done, glow: 0.6, light: lightLook) }
        else { Color.clear }   // idle, closed or never used: no orb. The space is kept so titles stay lined up.
    }
    func stateWord(_ s: Session) -> String { s.status == "closed" ? "closed" : ["needs you", "finished", "working", "idle", "unused"][s.rank] }
    func stateColor(_ s: Session) -> Color { s.rank == 0 ? lav : s.rank == 1 ? grn : s.rank == 2 ? ink.opacity(0.9) : ink.opacity(0.34) }

    /// A repo name with the small repository mark in front.
    func repoText(_ name: String, tone: Double = 0.45) -> Text {
        name.isEmpty ? Text("") : Text(Image(nsImage: RepoGlyph.image(tone, light: lightLook))).baselineOffset(-1.5) + Text(" " + name)
    }
    /// A branch name with the small git-branch mark in front, so it reads as a branch and not as a folder.
    func branchText(_ b: String?, lead: String = "", tone: Double = 0.45) -> Text {
        guard let b else { return Text("") }
        return Text(lead) + Text(Image(nsImage: BranchIcon.image(tone, light: lightLook))).baselineOffset(-1.5) + Text(" " + b)
    }

    /// One session on one line, its facts in columns that line up down the whole list.
    func sessionRow(_ s: Session, table: Bool) -> some View {
        let old = s.rank >= 3 && s.seconds >= 86_400   // idle since yesterday or earlier: shown quieter
        let repo = groupBy == "state" || s.status == "closed" ? s.project : ""
        return Hovering(id: s.id, onLeave: { if confirmClose == s.id { confirmClose = nil } }) { hovering in
        HStack(spacing: 12) {
            orb(s).frame(width: 12, height: 12).padding(.trailing, -3)
            if table {
                Text(s.title).font(.system(size: 13, weight: .medium)).foregroundStyle(ink.opacity(old ? 0.62 : 0.96))
                    .lineLimit(1).frame(width: 270, alignment: .leading)
                // The last thing you typed there; the recap if nothing has been typed.
                Text((showLast ? s.lastMessage : nil) ?? s.recap ?? "").font(.system(size: 12)).foregroundStyle(ink.opacity(old ? 0.28 : 0.5))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                // The repo and the branch are two pieces that shorten separately. As one line cut in the middle, a
                // long pair lost the branch icon and ran together ("storefront…saved-card-checkout"). The repo keeps up to
                // 40% of the column and the branch has the rest; each ends in "…" when it does not fit.
                GeometryReader { col in
                    HStack(spacing: 10) {
                        if !repo.isEmpty {
                            repoText(repo, tone: old ? 0.26 : 0.42).lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: s.branch == nil ? col.size.width : col.size.width * 0.4, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                        }
                        branchText(s.branch, tone: old ? 0.26 : 0.42).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .frame(width: col.size.width, height: col.size.height, alignment: .leading)
                }
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(ink.opacity(old ? 0.26 : 0.42))
                .frame(width: repo.isEmpty ? 170 : 250, height: 16)
                Text(stateWord(s)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(stateColor(s)).frame(width: 70, alignment: .leading)
                Text(s.age).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(ink.opacity(0.38)).frame(width: 52, alignment: .trailing)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.system(size: 13, weight: .medium)).foregroundStyle(ink.opacity(old ? 0.62 : 0.96)).lineLimit(1)
                    (Text(stateWord(s)).foregroundColor(stateColor(s)) + (Text("  \(s.age)" + (repo.isEmpty ? "" : "  ·  ")) + repoText(repo, tone: 0.4) + branchText(s.branch, lead: "  ·  ", tone: 0.4)).foregroundColor(ink.opacity(0.4)))
                        .font(.system(size: 11)).lineLimit(1)
                    if showLast, let asked = s.lastMessage {
                        Text(asked).font(.system(size: 11.5)).foregroundStyle(ink.opacity(old ? 0.3 : 0.62)).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 12).padding(.trailing, 16).padding(.vertical, table ? 7.5 : 6.5)
        // The session whose terminal is in front is highlighted, the same way as in the notch panel.
        // The session whose terminal is in front is highlighted, the same way as in the notch panel.
        .background(ink.opacity(s.id == model.currentId ? 0.11 : picked(s) ? 0.09 : hovering ? 0.05 : 0))
        .overlay(alignment: .leading) { if picked(s) { Rectangle().fill(ink.opacity(0.5)).frame(width: 2) } }
        .contentShape(Rectangle())
        
        // The single click acts at once. Listening for a double click the usual way made every single click wait
        // to see whether a second was coming, which felt like lag; here both are heard, independently.
        .onTapGesture { pick(s) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { app?.go(s) })
        .contextMenu { rowMenu(s) }
        }
    }

    /// One session as a card: its state on top, its name, where it is, and the last thing said in it.
    func sessionCard(_ s: Session) -> some View {
        let old = s.rank >= 3 && s.seconds >= 86_400
        let repo = groupBy == "state" || s.status == "closed" ? s.project : ""
        let here = s.id == model.currentId
        return Hovering(id: s.id, onLeave: { if confirmClose == s.id { confirmClose = nil } }) { hovering in
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if s.rank < 3 && s.status != "closed" { orb(s).frame(width: 12, height: 12) }
                Text(stateWord(s)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(stateColor(s))
                Text(s.age).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(ink.opacity(0.38))
                Spacer(minLength: 0)
            }
            .frame(height: 16)
            Text(s.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(ink.opacity(old ? 0.62 : 0.96))
                .lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            // The repo and the branch shorten separately, each ending in "…". As one line cut in the middle the two
            // ran together and the branch lost its icon ("storefront…saved-card-checkout").
            HStack(spacing: 10) {
                if !repo.isEmpty { repoText(repo, tone: old ? 0.26 : 0.42).lineLimit(1).truncationMode(.tail).layoutPriority(1) }
                branchText(s.branch, tone: old ? 0.26 : 0.42).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(ink.opacity(old ? 0.26 : 0.42))
            .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
            Text((showLast ? s.lastMessage : nil) ?? s.recap ?? " ").font(.system(size: 12)).foregroundStyle(ink.opacity(old ? 0.3 : 0.55))
                .lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(ink.opacity(here ? 0.12 : picked(s) ? 0.1 : hovering ? 0.07 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ink.opacity(picked(s) ? 0.55 : here ? 0.22 : 0.08), lineWidth: picked(s) ? 1 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        
        // The single click acts at once. Listening for a double click the usual way made every single click wait
        // to see whether a second was coming, which felt like lag; here both are heard, independently.
        .onTapGesture { pick(s) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { app?.go(s) })
        .contextMenu { rowMenu(s) }
        }
    }

    /// A click picks a session: its details show in the pane on the right, and "Go to session" (or a double-click, or
    /// Return) takes you there. When the window is too narrow for the pane, a click goes straight there.
    func pick(_ s: Session) { if paneShown { detailId = s.id } else { app?.go(s) } }
    func picked(_ s: Session) -> Bool { paneShown && detailId == s.id }

    @ViewBuilder func rowMenu(_ s: Session) -> some View {
        Button("Rename…") { app?.rename(s) }
        if s.status == "closed" { Button("Copy Resume Command") { copyResume(s) } }
        Button("Show folder in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.cwd) }
        if s.status != "closed" { Divider(); Button("Close Session…") { app?.askToEnd(s) } }
    }
    func copyResume(_ s: Session) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.resumeCommand, forType: .string)
    }

    /// One click between light and dark, in the stay-on-screen window only. It shows what a click gives you: a sun
    /// while dark, a moon while light. "Match the system" stays a choice in settings.
    var lookSwitch: some View {
        Image(systemName: lightLook ? "moon" : "sun.max").font(.system(size: 13)).foregroundStyle(ink.opacity(0.45))
            .frame(width: 16)
            .contentShape(Rectangle().inset(by: -6))
            .onTapGesture { UserDefaults.standard.set(lightLook ? "dark" : "light", forKey: "windowLook"); app?.applyWindowLook() }
            .help(lightLook ? "Switch to dark" : "Switch to light")
    }
    var gear: some View {
        Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(ink.opacity(0.45))
            .contentShape(Rectangle().inset(by: -6))
            .onTapGesture { app?.showSettings() }.help("Settings")
            .contextMenu {
                Button("Settings…") { app?.showSettings() }
                Divider()
                Button("Quit codehatch") { NSApp.terminate(nil) }
            }
    }
    /// The command that reopens a session from any terminal, shown in full with a copy button beside it.
    /// Seeing the command itself says what it is; a button labelled "copy resume" did not.
    func resumeLine(_ s: Session) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RESUME FROM A TERMINAL").font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(ink.opacity(0.35))
            HStack(spacing: 8) {
                Text(s.resumeCommand).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(ink.opacity(0.8))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 4)
                Image(systemName: copied == s.id ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ink.opacity(copied == s.id ? 0.95 : 0.6)).frame(width: 16)
                    .contentShape(Rectangle().inset(by: -6)).help("Copy")
                    .onTapGesture {
                        copyResume(s); copied = s.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copied == s.id { copied = nil } }
                    }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(lightLook ? Color.black.opacity(0.06) : Color.black.opacity(0.35)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ink.opacity(0.08), lineWidth: 0.5)))
        }
        .padding(.top, 20)
    }
    /// The x on a row. A session that is working or waiting on you asks once more before it closes.
    /// Shown for a few seconds after a close.
    @ViewBuilder var closedToast: some View {
        if let c = model.closed {
            HStack(spacing: 10) {
                Text("Closed \"\(c.title)\"").foregroundStyle(Color.white.opacity(0.85)).lineLimit(1)
                // Undo, in effect: put the session back where it was, in a new terminal.
                Text("Resume").foregroundStyle(.white).fontWeight(.semibold).fixedSize().contentShape(Rectangle())
                    .onTapGesture { model.closed = nil; if let s = c.session { app?.go(s) } }
            }
            .font(.system(size: 11.5, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 8)
            .background(Capsule().fill(Color(white: 0.16)).overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)))
            .padding(.bottom, 12).padding(.horizontal, 12)
            .transition(.opacity)
        }
    }

    /// Everything about one session: the one you last pointed at, or failing that the one that most wants you.
    @ViewBuilder var detailPane: some View {
        if let s = (model.sessions + model.recent).first(where: { $0.id == detailId }) ?? model.spotlight ?? model.sessions.first(where: { !$0.empty }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        orb(s).frame(width: 14, height: 14)
                        Text(stateWord(s)).font(.system(size: 12, weight: .medium)).foregroundStyle(stateColor(s))
                        Text(s.age == "now" ? "now" : "for \(s.age)").font(.system(size: 12)).foregroundStyle(ink.opacity(0.4))
                        Spacer()
                    }
                    Text(s.title).font(.system(size: 19, weight: .semibold)).foregroundStyle(ink.opacity(0.97))
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                    (repoText(s.project) + branchText(s.branch, lead: "  ·  ")).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(ink.opacity(0.45)).padding(.top, 5)
                    if let recap = s.recap { detailBlock("Where it is", recap) }
                    if let asked = s.lastAsked { detailBlock("You last asked", asked) }
                    if s.replyIsNewer, let reply = s.lastReply { detailBlock("Last reply", reply) }
                    if s.recap == nil && s.lastAsked == nil { detailBlock("Where it is", s.empty ? "Nothing has been asked in this session yet." : "No recap saved for this session yet.") }
                    HStack(spacing: 8) {
                        action(s.status == "closed" ? "Resume" : "Go to session", primary: true) { app?.go(s) }
                            .keyboardShortcut(.defaultAction)
                        action("Rename") { app?.rename(s) }
                    }
                    .padding(.top, 22)
                    if s.status == "closed" { resumeLine(s) }
                }
                .padding(22)
            }
        }
    }
    func detailBlock(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(ink.opacity(0.35))
            Text(text).font(.system(size: 13)).lineSpacing(3).foregroundStyle(ink.opacity(0.82)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(.top, 20)
    }
    func action(_ label: String, primary: Bool = false, _ act: @escaping () -> Void) -> some View {
        Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(primary ? paper : ink.opacity(0.85))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(primary ? ink.opacity(0.92) : ink.opacity(0.1)))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
    }

    @ViewBuilder var panelBody: some View {
        // Closed, the shape is exactly the notch: its width and the menu bar's height. On a Mac with no notch it is a
        // strip of no height at the top centre of the screen.
        let closedW: CGFloat = model.notchWidth > 0 ? model.notchWidth : 160
        // The notch's own height, not the menu bar's: the menu bar can be a point taller, and that point showed as a sliver
        // of black under the notch at the end of closing, just before the panel left the screen, like a bounce.
        let closedH: CGFloat = model.notchWidth > 0 ? (model.notchHeight > 0 ? model.notchHeight : model.barHeight) : 0
        VStack(spacing: 0) {
            pill.frame(height: model.barHeight)
            list.padding(.horizontal, 8)   // clear of the shape's sides, which sit a little in from the top corners
        }
        .frame(width: Self.openWidth, height: Self.openHeight, alignment: .top)
        .overlay(alignment: .bottom) { closedToast }
        .opacity(model.open ? 1 : 0)
        .modifier(Grow(progress: model.open ? 1 : 0, closed: CGSize(width: closedW, height: closedH), open: CGSize(width: Self.openWidth, height: Self.openHeight)))
        // Dark glass: the Mac's blur of whatever is behind, darkened, and solid black at the very top so it joins the
        // notch. This is the long-standing blur, not macOS 26's Liquid Glass: that one draws itself in over half a
        // second every time its size changes, pale and without its edge, which a panel that grows cannot hide. This
        // one is complete from the first frame, so the panel is glass the whole way open, with nothing to cover up.
        .background(
            ZStack {
                PanelBlur()
                Color.black.opacity(0.22)   // how dark the glass is: lower lets more of what is behind show through
                // Solid black for the height of the menu bar, so the top of the panel is one piece with the notch, then
                // easing into the glass below.
                VStack(spacing: 0) {
                    Color.black.frame(height: model.barHeight + 4)
                    // One slow fade the whole way down, never a hard line: nearly black at the top, still dark through the
                    // middle, and only the bottom part of the panel is the clear glass.
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.92), location: 0.2), .init(color: .black.opacity(0.8), location: 0.45), .init(color: .black.opacity(0.55), location: 0.68), .init(color: .black.opacity(0.22), location: 0.87), .init(color: .black.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
                }
            }
        )
        // The notch's own outline, grown: the top corners curve outward into the top edge of the screen, the way the
        // notch itself meets it, and the bottom corners are rounded. No drawn edge; the shape is the edge.
        .clipShape(NotchShape(top: model.open ? 10 : 6, bottom: model.open ? 18 : 9))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var dots: some View {
        PortalMark(active: model.active.count)
    }
    var brand: some View {
        HStack(spacing: 8) {
            // No logo: a native tool does not need to sign its own panel. Just the session that most recently
            // asked for you, or failing that the one working now.
            if let s = model.spotlight {
                // The same orb as on the session's row: turning while it works, still when it needs you, green when done.
                orb(s).frame(width: 12, height: 12)
                // The orb says the state; the words are the session's name. The same as beside the closed notch.
                Text(s.title).foregroundStyle(ink.opacity(0.88)).lineLimit(1).truncationMode(.tail)
                .font(.system(size: 11.5, weight: .medium))
                .contentShape(Rectangle())
                
                .onTapGesture { app?.go(s) }
            }
        }
    }
    var stats: some View {
        Text(model.summary).font(.system(size: 11.5, weight: .medium)).foregroundStyle(ink.opacity(0.6)).lineLimit(1).fixedSize()
    }
    /// The counts for a space of limited width: the fullest version that fits, so they never run under the camera.
    var fittedStats: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(model.summaries, id: \.self) { line in
                Text(line).font(.system(size: 11.5, weight: .medium)).foregroundStyle(ink.opacity(0.6)).lineLimit(1).fixedSize()
            }
        }
    }
    @ViewBuilder var pill: some View {
        if model.notchWidth > 0 {
            // Either side of the camera: the stats on its left, the portal on its right.
            let side = (Self.openWidth - model.notchWidth) / 2
            HStack(spacing: 0) {
                brand.padding(.leading, 18).frame(width: side, alignment: .leading)
                Color.clear.frame(width: model.notchWidth)
                fittedStats.padding(.leading, 10).padding(.trailing, 18).frame(width: side, alignment: .trailing)
            }
        } else {
            HStack { brand; Spacer(); stats }.padding(.horizontal, 18)
        }
    }

    var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(ink.opacity(0.45))
                TextField("", text: $model.query, prompt: Text("Search sessions").foregroundStyle(ink.opacity(0.35)))
                    .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(ink).tint(ink)
                    .focused($searchFocused)
                if !detached {
                    Image(systemName: "macwindow.on.rectangle").font(.system(size: 13)).foregroundStyle(ink.opacity(0.45))
                        .contentShape(Rectangle().inset(by: -6))   // a hand, like every other button here
                        .onTapGesture { app?.toggleWidget() }
                        .help("Keep a copy on screen that you can move to another display")
                }
                gear
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
            .onChange(of: model.open) { _, isOpen in searchFocused = isOpen }
            .onChange(of: model.query) { _, _ in model.selected = 0 }
            // One click to see a single repo. Only shown when there is more than one to choose between.
            if !detached && (model.repoNames.count > 1 || !model.recent.isEmpty) {
                // With many repos the chips wrap onto a second line, and a third, so every one stays in view.
                    Wrap(spacing: 6) {
                        chip("All", model.sessions.count, on: model.repoFilter == nil) { model.repoFilter = nil; model.selected = hereIndex }
                        ForEach(model.repoNames, id: \.self) { name in
                            chip(name, model.sessions.filter { $0.project == name }.count, on: model.repoFilter == name) {
                                model.repoFilter = model.repoFilter == name ? nil : name; model.selected = hereIndex
                            }
                        }
                        if !model.recent.isEmpty {
                            chip("Recently closed", model.recent.count, on: model.repoFilter == Model.closedOnly) {
                                model.repoFilter = model.repoFilter == Model.closedOnly ? nil : Model.closedOnly; model.selected = hereIndex
                            }
                        }
                    }.padding(.horizontal, 14).padding(.bottom, 9)
            }
            Rectangle().fill(ink.opacity(0.08)).frame(height: 1)
            GeometryReader { geo in
                let rows = model.filtered
                ScrollViewReader { _ in
                ScrollView {
                    Group {
                        // Narrow: one column, repos one under another.
                        VStack(spacing: 2) {
                            // By recency each row names its own repo; by repo there is a heading per repo.
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, s in
                                if byRepo && (i == 0 || rows[i - 1].project != s.project) {
                                    repoHeader(s.project, count: rows.filter { $0.project == s.project }.count).padding(.top, i == 0 ? 4 : 14)
                                }
                                row(s, selected: i == model.selected && !detached, showRepo: !byRepo)
                            }
                            // Sessions that are no longer open. Clicking one reopens it in a new terminal.
                            let past = model.recentHits
                            if !past.isEmpty {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 10, weight: .medium)).foregroundStyle(ink.opacity(0.45))
                                    Text("Recently closed").font(.system(size: 11, weight: .semibold)).foregroundStyle(ink.opacity(0.5))
                                    Text("click to resume").font(.system(size: 11)).foregroundStyle(ink.opacity(0.25))
                                    Spacer()
                                }.padding(.horizontal, 12).padding(.top, rows.isEmpty ? 4 : 14).padding(.bottom, 2)
                                // One fold per repo, shut to begin with: a long tail of old sessions stays out of the way
                                // until you want one. Searching opens the repos that have matches.
                                ForEach(repos(in: past), id: \.self) { name in
                                    closedRepoHeader(name, count: past.filter { $0.project == name }.count, open: closedFoldOpen(name)).padding(.horizontal, 4)
                                    if closedFoldOpen(name) {
                                        ForEach(past.filter { $0.project == name }) { s in row(s, selected: false, showRepo: false) }
                                    }
                                }
                            }
                        }.padding(8)
                    }
                }
                }
            }
        }
        .frame(height: detached ? nil : Self.openHeight - model.barHeight)
    }

    func repos(in rows: [Session]) -> [String] { var out: [String] = []; for s in rows where !out.contains(s.project) { out.append(s.project) }; return out }

    /// A repo's fold inside "Recently closed": click to show or hide its sessions.
    func closedRepoHeader(_ name: String, count: Int, open: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(ink.opacity(0.4)).rotationEffect(.degrees(open ? 90 : 0))
            RepoIcon().stroke(ink.opacity(0.5), style: StrokeStyle(lineWidth: 1.05, lineCap: .round, lineJoin: .round)).frame(width: 10.5, height: 10.5)
            Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(ink.opacity(0.7))
            Text("\(count)").font(.system(size: 11)).foregroundStyle(ink.opacity(0.3)).monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { if model.query.isEmpty { toggle(&openClosed, name) } else { toggle(&shutInSearch, name) } } }
    }
    func repoHeader(_ name: String, count: Int) -> some View {
        HStack {
            RepoIcon().stroke(ink.opacity(0.45), style: StrokeStyle(lineWidth: 1.05, lineCap: .round, lineJoin: .round)).frame(width: 10.5, height: 10.5)
            Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(ink.opacity(0.5))
            Text("\(count)").font(.system(size: 11)).foregroundStyle(ink.opacity(0.25))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.bottom, 3)
    }

    func row(_ s: Session, selected: Bool, showRepo: Bool = false) -> some View {
        Hovering(id: s.id, onLeave: { if confirmClose == s.id { confirmClose = nil } }) { hovering in
        HStack(alignment: .top, spacing: 8) {
            Group {
                if s.rank == 2 { Orb(tint: PortalMark.working, light: lightLook) }
                else if s.rank == 0 { Orb(spinning: false, light: lightLook) }
                else if s.rank == 1 { Orb(spinning: false, tint: PortalMark.done, glow: 0.6, light: lightLook) }
                else { Color.clear }   // idle, closed or never used: no orb. The space is kept so titles stay lined up.
            }.frame(width: 12, height: 12).padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(s.title).font(.system(size: 13, weight: .medium)).foregroundStyle(ink.opacity(0.95)).lineLimit(1)
                }
                (repoText(showRepo ? s.project : "") + branchText(s.branch, lead: showRepo ? "  ·  " : ""))
                    .font(.system(size: 11)).foregroundStyle(ink.opacity(0.45)).lineLimit(1)
                // In the notch panel: the last thing you typed there, on one line, cut short if it is long.
                if !detached, showLast, let asked = s.lastMessage {
                    Text(asked).font(.system(size: 11.5)).foregroundStyle(ink.opacity(0.62)).lineLimit(1).truncationMode(.tail)
                }
                // Where the session is. Shown in the stay-on-screen window, where there is room for it.
                if detached, let recap = s.gist {
                    Text(recap).font(.system(size: 11.5)).foregroundStyle(ink.opacity(0.66)).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
            }
            Spacer()
            // The time, at the far right in fixed-width digits: it can count up without moving anything else.
            // The state and how long it has been in it, together at the far right: the repo and branch below are
            // then one uninterrupted line. Fixed-width digits, so the time can count without moving anything.
            (Text(s.statusText).foregroundColor(s.rank == 1 ? PortalMark.done : s.rank == 0 ? PortalMark.amber : ink.opacity(s.rank == 2 ? 0.7 : 0.4))
             + Text("  " + s.age).foregroundColor(ink.opacity(0.4)))
                .font(.system(size: 11)).monospacedDigit().fixedSize().padding(.top, 2.5)
        }
        .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(ink.opacity(selected ? 0.11 : hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        
        .onTapGesture { dbg("row clicked: \(s.title)"); app?.go(s) }
        .contextMenu {
            Button("Rename…") { app?.rename(s) }
            if s.status == "closed" { Button("Copy Resume Command") { copyResume(s) } }
            Button("Show folder in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.cwd) }
            if s.status != "closed" { Divider(); Button("Close Session…") { app?.askToEnd(s) } }
        }
        }
    }
}

/// One orb for every state, so they belong together: a swirl of light around a bright core.
/// Working turns and breathes. Needs-you is the same orb held still. Idle is a small dim grey one.
struct Orb: View {
    var spinning = true
    var tint: Color = PortalMark.amber
    var size: CGFloat = 11
    var glow: Double = 1
    /// On a light background. The usual orb is light itself (white in the swirl, a white core, a glow), which is
    /// nearly invisible on white. There it is drawn as a small saturated gem instead: deep colour, a bright spot.
    var light = false
    /// The middle of the orb on a light background: a paler shade of its own colour, soft-edged. A white dot there
    /// looked like a hole punched in it.
    static func heart(_ tint: NSColor) -> NSColor {
        let base = tint == NSColor(PortalMark.amber) ? NSColor(red: 1.0, green: 0.72, blue: 0.30, alpha: 1) : tint == NSColor(PortalMark.working) ? NSColor(red: 0.30, green: 0.62, blue: 1.0, alpha: 1) : tint
        return (base.blended(withFraction: 0.45, of: .white) ?? base).withAlphaComponent(0.9)
    }
    /// The swirl's colours, going round.
    static func swirl(_ tint: NSColor, light: Bool) -> [NSColor] {
        let amber = tint == NSColor(PortalMark.amber)
        if light {
            // Darkening the working blue turned it a dull slate. It gets a vivid blue and a deep royal one instead.
            let blue = tint == NSColor(PortalMark.working)
            let base = amber ? NSColor(red: 0.98, green: 0.55, blue: 0.05, alpha: 1) : blue ? NSColor(red: 0.13, green: 0.50, blue: 1.0, alpha: 1) : (tint.blended(withFraction: 0.22, of: .black) ?? tint)
            let deep = amber ? NSColor(red: 0.90, green: 0.30, blue: 0.02, alpha: 1) : blue ? NSColor(red: 0.02, green: 0.28, blue: 0.86, alpha: 1) : (tint.blended(withFraction: 0.5, of: .black) ?? tint)
            let pale = base.blended(withFraction: 0.2, of: .white) ?? base   // only a little lighter: a pale patch on white reads as a bite out of the orb
            return [pale, base, deep, base, pale]
        }
        // The deep stretch is let through only in part, like the blue and green orbs' thin stretch: a soft dark spot, not a solid ball.
        if amber { return [.white, NSColor(red: 1.0, green: 0.80, blue: 0.36, alpha: 1), NSColor(PortalMark.ember).withAlphaComponent(0.42), tint, .white] }
        return [.white, tint, NSColor.white.withAlphaComponent(0.08), tint.withAlphaComponent(0.6), .white]
    }
    var body: some View {
        if spinning {
            // Moving orbs are drawn and animated by the system's compositor. A SwiftUI animation that repeats
            // forever makes the whole window lay itself out again on every frame, which showed up as a
            // steady 10% of a processor core while anything was working.
            SpinningOrb(tint: NSColor(tint), light: light).frame(width: size, height: size)
        } else {
            ZStack {
                // Blue and green darken handsomely where the swirl thins out. Amber does not: darkened, it is brown, and
                // the orb looks like dull metal. So the amber orb's thin stretch is a deeper, hotter orange instead.
                Circle().fill(AngularGradient(colors: Self.swirl(NSColor(tint), light: light).map { Color(nsColor: $0) }, center: .center))
                    .rotationEffect(.degrees(35))
                Circle().fill(RadialGradient(colors: [light ? Color(nsColor: Self.heart(NSColor(tint))) : .white, (light ? Color(nsColor: Self.heart(NSColor(tint))) : .white).opacity(0)], center: .center, startRadius: 0, endRadius: size * (light ? 0.34 : 0.3)))
            }
            .frame(width: size, height: size)
            .shadow(color: (tint == PortalMark.amber ? PortalMark.ember : tint).opacity(light ? 0 : glow * (tint == PortalMark.amber ? 0.9 : 0.75)), radius: light || glow <= 0 ? 0 : 5)
        }
    }
}

struct PulsingGlow: NSViewRepresentable {
    func makeNSView(context: Context) -> GlowLayerView { GlowLayerView() }
    func updateNSView(_ v: GlowLayerView, context: Context) {}
}
/// A soft amber glow that fades in and out, animated by the compositor.
final class GlowLayerView: NSView {
    private let dot = CALayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = false
        let c = NSColor(PortalMark.amber)
        dot.backgroundColor = c.withAlphaComponent(0.25).cgColor
        dot.shadowColor = c.cgColor; dot.shadowOffset = .zero; dot.shadowRadius = 7; dot.shadowOpacity = 1
        layer?.addSublayer(dot)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.frame = bounds.insetBy(dx: 3, dy: 2); dot.cornerRadius = 4
        CATransaction.commit()
        animate()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); animate() }
    private func animate() {
        guard window != nil, dot.animation(forKey: "pulse") == nil else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.25; a.toValue = 1; a.duration = 1.4; a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); a.isRemovedOnCompletion = false
        dot.add(a, forKey: "pulse")
    }
}

struct SpinningOrb: NSViewRepresentable {
    let tint: NSColor
    var light = false
    func makeNSView(context: Context) -> OrbLayerView { let v = OrbLayerView(); v.light = light; v.tint = tint; return v }
    func updateNSView(_ v: OrbLayerView, context: Context) { if v.light != light { v.light = light }; if v.tint != tint { v.tint = tint } }
}
/// The working orb as layers: a swirl that turns, a bright core, and a glow that breathes.
final class OrbLayerView: NSView {
    private let body = CALayer(), ring = CAGradientLayer(), core = CAGradientLayer()
    var tint = NSColor.white { didSet { paint() } }
    var light = false { didSet { paint() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        ring.type = .conic; ring.startPoint = CGPoint(x: 0.5, y: 0.5); ring.endPoint = CGPoint(x: 0.5, y: 0); ring.masksToBounds = true
        core.type = .radial; core.startPoint = CGPoint(x: 0.5, y: 0.5); core.endPoint = CGPoint(x: 0.8, y: 0.8)
        core.colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        body.shadowOffset = .zero; body.shadowRadius = 5
        body.addSublayer(ring); body.addSublayer(core)
        layer?.addSublayer(body)
        paint()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func paint() {
        ring.colors = Orb.swirl(tint, light: light).map(\.cgColor)
        let heart = light ? Orb.heart(tint) : NSColor.white
        core.colors = [heart.cgColor, heart.withAlphaComponent(0).cgColor]
        body.shadowColor = light ? NSColor.clear.cgColor : tint.cgColor; body.shadowRadius = 5   // no glow on a light background
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        body.frame = bounds; ring.frame = bounds; core.frame = bounds
        ring.cornerRadius = bounds.width / 2
        CATransaction.commit()
        animate()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); animate() }
    /// Layer animations are dropped when a view leaves its window, so they are put back whenever it has one.
    private func animate() {
        guard window != nil, ring.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0; spin.toValue = -2 * Double.pi; spin.duration = 1.5; spin.repeatCount = .infinity; spin.isRemovedOnCompletion = false
        ring.add(spin, forKey: "spin")
        func breathe(_ key: String, _ from: Double, _ to: Double) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from; a.toValue = to; a.duration = 1.1; a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); a.isRemovedOnCompletion = false
            body.add(a, forKey: key)
        }
        breathe("transform.scale", 0.92, 1.08)
        breathe("shadowOpacity", 0.45, 0.95)
    }
}
/// A pointing-hand cursor over things you can click.

/// The codehatch portal arch. Dim when nothing is happening; glows and shows a count when sessions are active.
/// The surface behind the panel and the window: Liquid Glass on macOS 26 and later, darkened so white text
/// stays readable over anything; the older frosted blur everywhere else.
/// The blur behind the notch panel: the Mac's own dark translucent material. Told to stay "active", so it looks the
/// same whether or not the panel is the focused window.
/// The status tab's outline: like the notch's own, its outer top corner curves outward into the top edge of the screen,
/// and its outer bottom corner is rounded. The far end (lying over the notch) is square at the top and rounded at the
/// bottom, matching the notch's corner.
struct TabShape: Shape {
    static let flare: CGFloat = 6
    var near: CGFloat = 10
    var far: CGFloat
    func path(in r: CGRect) -> Path {
        let f = Self.flare
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + f, y: r.minY + f), control: CGPoint(x: r.minX + f, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + f, y: r.maxY - near))
        p.addQuadCurve(to: CGPoint(x: r.minX + f + near, y: r.maxY), control: CGPoint(x: r.minX + f, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - far, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - far), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// The status tab coming out of the notch: everything left of the notch is uncovered from the notch outward, and the
/// orb and name fade in as they are uncovered. At 0 only the part over the notch is left, which cannot be seen.
struct OutOfNotch: ViewModifier, Animatable {
    var shown: CGFloat
    let notch: CGFloat
    var animatableData: CGFloat { get { shown } set { shown = newValue } }
    func body(content: Content) -> some View {
        content
            .mask(alignment: .trailing) {
                GeometryReader { g in
                    Rectangle().frame(width: notch + max(0, g.size.width - notch) * max(0, shown)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }
            .opacity(notch > 0 ? 1 : Double(min(1, shown * 1.5)))   // without a notch to come out of, it also fades
    }
}

/// Which row or card the pointer is over, worked out by codehatch itself for the whole window: every row reports where
/// it is, and every pointer movement anywhere is checked against those places. SwiftUI's own per-view hover tracking
/// only delivers a change when the next event arrives in an app that is not in front (codehatch never is), so the
/// highlight lagged one movement behind, or waited for a nudge of the mouse. Pointer movements reach codehatch
/// promptly through its event monitors, which is what the notch itself already relies on.
final class PointerTracker: ObservableObject {
    static let panel = PointerTracker(), window = PointerTracker(), menu = PointerTracker()
    @Published private(set) var over: String?
    private var places: [String: CGRect] = [:]
    private var last: CGPoint?
    /// A row moved (the list scrolled, or a session moved up): check again with the pointer where it last was, so the
    /// highlight follows the row under a pointer that has not moved.
    func place(_ id: String, _ rect: CGRect) {
        places[id] = rect
        if let last, rect.contains(last) || over == id { DispatchQueue.main.async { self.pointer(at: self.last) } }
    }
    func forget(_ id: String) { places[id] = nil; if over == id { over = nil } }
    /// The pointer is at this point, in the window's content (top-left origin), or outside the window (nil).
    func pointer(at p: CGPoint?) {
        last = p
        let now = p.flatMap { p in places.first { $0.value.contains(p) }?.key }
        if now != over {
            over = now
            if UserDefaults.standard.bool(forKey: "debugHover") { dbg(String(format: "pointer over %@ %.3f", now ?? "nothing", Date().timeIntervalSince1970)) }
        }
    }
}

/// The panel under the menu bar icon: the same five choices a menu would have, drawn by codehatch.
struct MenuPanel: View {
    weak var app: AppDelegate?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            item("sessions", "Show sessions")
            item("window", "Open the window")
            Divider().padding(.horizontal, 12).padding(.vertical, 5)
            item("settings", "Settings…", key: "⌘,")
            item("updates", "Check for updates…")
            Divider().padding(.horizontal, 12).padding(.vertical, 5)
            item("quit", "Quit codehatch", key: "⌘Q")
        }
        .padding(6)
        .frame(width: 240, height: 182, alignment: .top)
        // Darker than a plain blur, to match the system's own menu bar panels (Wi-Fi, Battery) beside it.
        .background(ZStack { PanelBlur(light: scheme == .light); (scheme == .light ? Color.white.opacity(0.35) : Color.black.opacity(0.38)) })
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
    func item(_ id: String, _ title: String, key: String = "") -> some View {
        Hovering(id: id) { over in
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if !key.isEmpty { Text(key).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(over ? 0.1 : 0)))
            .contentShape(Rectangle())
            .onTapGesture { app?.menuChose(id) }
        }
    }
}

/// A row or card that is highlighted while the pointer is over it.
struct Hovering<Content: View>: View {
    let id: String
    var onLeave: () -> Void = {}
    @ViewBuilder let content: (Bool) -> Content
    @EnvironmentObject private var pointer: PointerTracker
    var body: some View {
        content(pointer.over == id)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { pointer.place(id, g.frame(in: .global)) }
                    .onChange(of: g.frame(in: .global)) { _, r in pointer.place(id, r) }
                    .onDisappear { pointer.forget(id) }
            })
            .onChange(of: pointer.over == id) { was, now in if was && !now { onLeave() } }
    }
}

/// The panel's size as it opens and closes, between exactly the notch and exactly full size, and never outside those.
/// A spring creeps over its last few points, and may go a little past its mark. Both are absorbed here: the size reaches
/// the notch's exact size a touch before the spring has finished, and holds there. So closing ends the moment the shape
/// is the notch, with no sliver lingering around it and no moment where the shape is narrower than the notch.
struct Grow: ViewModifier, Animatable {
    var progress: CGFloat
    let closed: CGSize
    let open: CGSize
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        let q = max(0, min(1, (progress - 0.035) / 0.95))
        content.frame(width: closed.width + (open.width - closed.width) * q, height: closed.height + (open.height - closed.height) * q, alignment: .top)
    }
}

/// The shape of a panel hanging from the top of the screen. It is full width only along the very top; just below, each
/// side curves inward (the same outward flare the notch has where it meets the screen's edge), then runs straight down
/// to a rounded bottom corner.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        let t = min(top, r.width / 4, r.height / 2), b = min(bottom, r.width / 4, max(0, r.height - t))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct PanelBlur: NSViewRepresentable {
    var light = false
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow; v.state = .active
        paint(v)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { paint(v) }
    private func paint(_ v: NSVisualEffectView) {
        v.material = light ? .sidebar : .hudWindow
        v.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    }
}

struct GlassBack<S: Shape>: View {
    let shape: S
    let dim: Double
    let frosted: Color
    /// Extra black laid over the glass. The system turns glass pale when its window is not the focused one,
    /// and the stay-on-screen window almost never is, so its darkness cannot be left to the glass alone.
    var shade: Double = 0
    /// What the glass is tinted and overlaid with: black for the dark look, white for the light one.
    var tone: Color = .black
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            ZStack { Color.clear.glassEffect(.regular.tint(tone.opacity(dim)), in: shape); shape.fill(tone.opacity(shade)) }
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
    static func image(_ tone: Double, light: Bool = false) -> NSImage {
        let key = light ? -tone : tone
        if let i = made[key] { return i }
        let size: CGFloat = 12, k = size / 16
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let t = NSAffineTransform(); t.scale(by: k); t.concat()
            (light ? NSColor.black : NSColor.white).withAlphaComponent(tone).setStroke()
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
        made[key] = img
        return img
    }
}

/// The repository mark as an image, for placing inside a line of text beside a repo name.
enum RepoGlyph {
    static var made: [Double: NSImage] = [:]
    static func image(_ tone: Double, light: Bool = false) -> NSImage {
        let key = light ? -tone : tone
        if let i = made[key] { return i }
        let size: CGFloat = 11.5, k = size / 16
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let t = NSAffineTransform(); t.scale(by: k); t.concat()
            (light ? NSColor.black : NSColor.white).withAlphaComponent(tone).setStroke()
            let p = NSBezierPath(roundedRect: NSRect(x: 2.75, y: 1.5, width: 10.5, height: 12.5), xRadius: 1.6, yRadius: 1.6)
            p.lineWidth = 1.6; p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.move(to: NSPoint(x: 2.75, y: 10.5)); p.line(to: NSPoint(x: 13.25, y: 10.5))
            p.move(to: NSPoint(x: 5.5, y: 12.3)); p.line(to: NSPoint(x: 5.5, y: 15.4)); p.line(to: NSPoint(x: 7, y: 14.4)); p.line(to: NSPoint(x: 8.5, y: 15.4)); p.line(to: NSPoint(x: 8.5, y: 12.3))
            p.stroke()
            return true
        }
        made[key] = img
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
    /// "Needs you": a warm amber, the colour of waiting, clearly apart from the blue of working.
    static let amber = Color(red: 1.0, green: 0.67, blue: 0.24)
    /// The deep end of the amber orb's swirl.
    static let ember = Color(red: 1.0, green: 0.40, blue: 0.08)
    /// Working: the blue macOS uses for anything in progress.
    static let working = Color(red: 0.25, green: 0.59, blue: 1.0)
    /// Finished: a soft green, the usual colour for done.
    static let done = Color(red: 0.35, green: 0.87, blue: 0.55)
    // Loaded from inside the app itself, never from the project folder.
    static let image: NSImage? = Bundle.main.url(forResource: "portal", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        Group {
            if let img = Self.image {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
            } else {
                Arch().stroke(Self.amber, style: StrokeStyle(lineWidth: 1.8, lineCap: .round)).frame(width: 10, height: 13)
            }
        }
        // The mark is a plain white line drawing: no glow or shadow, which would only soften it.
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

    func applicationDidFinishLaunching(_ note: Notification) {
        AppDelegate.shared = self
        Prefs.register()
        // --dump: print everything the interface would show, as JSON, and quit without showing anything. Tests read this.
        if CommandLine.arguments.contains("--dump") { Dump.run(); exit(0) }
        // --close-and-exit <pid>: close one session the way the x does, wait for it, and quit. Tests use this.
        if let i = CommandLine.arguments.firstIndex(of: "--close-and-exit"), i + 1 < CommandLine.arguments.count, let pid = Int32(CommandLine.arguments[i + 1]) {
            Closer.close(pid); exit(0)
        }
        // --focus-terminal <pid>: bring the Terminal or iTerm2 tab running this process to the front, the way clicking
        // its session does, print what happened, and quit. --terminal-run <kind> <folder> <command>: open a new tab
        // there and run the command, the way resuming a session does. Both are for the tests.
        if let i = CommandLine.arguments.firstIndex(of: "--focus-terminal"), i + 1 < CommandLine.arguments.count, let pid = Int32(CommandLine.arguments[i + 1]) {
            let app = Loader.owner(of: pid).app ?? ""
            guard let kind = Terminals.kind(app), let tty = Terminals.tty(of: pid) else { print("not-a-terminal app=\(app)"); exit(1) }
            print(Terminals.focus(kind, tty: tty) ? "ok \(kind) \(tty)" : "not-found \(kind) \(tty)"); exit(0)
        }
        // --check-denial <text>: say whether this AppleScript error means macOS refused permission. For the tests.
        if let i = CommandLine.arguments.firstIndex(of: "--check-denial"), i + 1 < CommandLine.arguments.count {
            print(Terminals.isDenial(CommandLine.arguments[i + 1]) ? "denied" : "other"); exit(0)
        }
        // --front-tab <kind>: print the terminal device of the tab in front, which is how the session you are in is
        // found in Terminal and iTerm2. For the tests.
        if let i = CommandLine.arguments.firstIndex(of: "--front-tab"), i + 1 < CommandLine.arguments.count {
            print(Terminals.frontTTY(CommandLine.arguments[i + 1]) ?? "none"); exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--terminal-run"), i + 3 < CommandLine.arguments.count {
            Terminals.run(CommandLine.arguments[i + 1], in: CommandLine.arguments[i + 2], command: CommandLine.arguments[i + 3]); exit(0)
        }
        // --setup-selftest <folder> <editor ids, comma separated>: do what the welcome window's button does, with a stand-in
        // home folder for the hooks (and CODEHATCH_HELPER_DIR for the helper), print how each part went, and quit.
        if let i = CommandLine.arguments.firstIndex(of: "--setup-selftest"), i + 2 < CommandLine.arguments.count {
            Hooks.homeOverride = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let ids = CommandLine.arguments[i + 2].split(separator: ",").map(String.init)
            let r = Setup.run(hooks: true, editors: ids)
            UserDefaults.standard.removeObject(forKey: "liveUpdates")   // the selftest must not switch the real setting on
            let out = r.map { ["what": $0.what, "problem": $0.problem ?? ""] }
            if let data = try? JSONSerialization.data(withJSONObject: out) { FileHandle.standardOutput.write(data); print("") }
            exit(0)
        }
        // --render <dashboard|panel|settings|setup> <light|dark> <file.png>: draw that part of the interface, with the sample
        // sessions, straight to a picture, and print its size and how light it is. Nothing appears on screen. For the tests.
        if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 3 < CommandLine.arguments.count {
            Render.run(CommandLine.arguments[i + 1], look: CommandLine.arguments[i + 2], to: CommandLine.arguments[i + 3]); exit(0)
        }
        // --hooks-selftest <folder>: install and then remove the hooks inside a stand-in home folder, print what
        // happened, and quit without showing anything. Used to check the settings edits on copies.
        if let i = CommandLine.arguments.firstIndex(of: "--hooks-selftest"), i + 1 < CommandLine.arguments.count {
            Hooks.homeOverride = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            print("install:", Hooks.set(true) ?? "ok")
            if CommandLine.arguments.contains("--keep") { exit(0) }
            print("remove:", Hooks.set(false) ?? "ok")
            exit(0)
        }
        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Not .clear: SwiftUI's hover detection fails sporadically in a window whose background is exactly clear, for
        // any view that does not fill the whole window (Apple bug FB11988707) - which showed as rows that did not
        // highlight, or only after a nudge of the mouse. A black at 0.1% opacity cannot be seen and avoids it.
        panel.isOpaque = false; panel.backgroundColor = NSColor(white: 0, alpha: 0.001); panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)   // just above the menu bar, the usual level for a notch app
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.contentView = FirstClickHost(rootView: RootView(model: model, app: self).environmentObject(PointerTracker.panel))
        setUpBeacon()
        setUpMenu()
        setUpStatusItem()
        if Setup.wanted || CommandLine.arguments.contains("--setup") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.showSetup() } }
        if !Demo.on, ProcessInfo.processInfo.environment["CODEHATCH_HOME"] == nil { updater.startUpdater() }
        place()   // nothing is shown until the hotkey is pressed
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
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if let self, self.menuPanel?.isVisible == true, Int(e.keyCode) == kVK_Escape { self.closeMenuPanel(); return nil }
            return self?.key(e) == true ? nil : e
        }
        // A click in one of codehatch's own windows, outside the menu bar panel, closes it too.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            if let self, let p = self.menuPanel, p.isVisible, e.window !== p, e.window !== self.statusItem?.button?.window { self.closeMenuPanel() }
            return e
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.model.open == true { self?.close() }
            if self?.menuPanel?.isVisible == true { self?.closeMenuPanel() }   // a click in another app
        }
        refresh()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        watch()
        // The pointer is followed by being told when it moves, not by asking where it is on a timer, so the app does
        // nothing at all while the pointer is still. The usual way for a notch app: one monitor for
        // movements over other apps, one for movements over our own windows, and a check against the notch's area.
        let moved: (NSEvent) -> Void = { [weak self] _ in
            guard let self else { return }
            if !self.sawPointer { self.sawPointer = true; dbg("pointer: movements are arriving") }
            self.trackMouse()
            self.followPointer()
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: moved)
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { e in moved(e); return e }
        panel.acceptsMouseMovedEvents = true
    }
    var sawPointer = false
    /// Tell each window's pointer tracker where the pointer is now, in that window's own coordinates.
    private var pointerWasOver = false
    func followPointer() {
        let m = NSEvent.mouseLocation
        // Away from all of codehatch's windows there is nothing to do, beyond clearing a highlight once on the way out.
        let over = [model.open ? panel : nil, widget, menuPanel].contains { $0?.isVisible == true && $0!.frame.contains(m) }
        if !over && !pointerWasOver { return }
        pointerWasOver = over
        func inside(_ w: NSWindow?) -> CGPoint? {
            guard let w, w.isVisible, let v = w.contentView, w.frame.contains(m) else { return nil }
            return v.convert(w.convertPoint(fromScreen: m), from: nil)
        }
        PointerTracker.panel.pointer(at: model.open ? inside(panel) : nil)
        PointerTracker.window.pointer(at: inside(widget))
        PointerTracker.menu.pointer(at: inside(menuPanel))
        // The cursor: an I-beam over a text field, the arrow everywhere else. macOS only keeps the cursor up to date for
        // the app in front, so in codehatch the I-beam from the search field stayed on over buttons and icons.
        for w in [model.open ? panel : nil, widget].compactMap({ $0 }) where w.isVisible && w.frame.contains(m) {
            let hit = w.contentView?.hitTest(w.convertPoint(fromScreen: m))
            let text = hit is NSText || hit is NSTextField || hit?.superview is NSTextField
            (text ? NSCursor.iBeam : NSCursor.arrow).set()
        }
    }
    var hoverTimer: Timer?
    /// True while the pointer is pushed into the notch (or the top centre of a screen without one).
    func pointerInNotch() -> Bool {
        let m = NSEvent.mouseLocation
        guard let s = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) else { return false }
        var w: CGFloat = 200
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea { w = max(120, s.frame.width - l.width - r.width) }
        return m.y >= s.frame.maxY - 4 && abs(m.x - s.frame.midX) < w / 2
    }

    var changed = true, lastLoad = 0.0
    var stream: FSEventStreamRef?
    /// macOS reports the moment Claude Code rewrites a session's status file, or the editor helper notes a new
    /// front terminal. The list is reloaded then, so it is current within a fraction of a second and the app
    /// does nothing at all while nothing is happening.
    func watch() {
        let home = Loader.home.path
        // Codex keeps no small status file per session as Claude Code does, but it writes each session's log as it goes,
        // under ~/.codex/sessions; watching that folder catches a Codex session starting, finishing or stopping for you
        // as soon as it happens, hooks or not.
        let paths = ["\(home)/.claude/sessions", "\(home)/.codehatch", "\(home)/.codex"].filter { FileManager.default.fileExists(atPath: $0) } as CFArray
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let st = FSEventStreamCreate(nil, { _, info, _, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
            // A working session rewrites its file constantly without anything you can see changing. Look at just
            // the files that changed, and carry on only if one of them now says something different.
            let files = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            guard files.isEmpty || files.contains(where: me.matters) else { return }
            me.changed = true
            // A working session can rewrite its file many times a second: reload at most once every two seconds.
            if Date().timeIntervalSince1970 - me.lastLoad >= 2 { me.tick() }
        }, &ctx, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { dbg("watch: could not start"); return }
        FSEventStreamSetDispatchQueue(st, .main)
        FSEventStreamStart(st)
        stream = st
    }
    /// A Codex log grows with every step of a turn. Only the steps that change what is shown count: a turn starting or
    /// ending, a prompt, an interruption, or a request for approval. Everything else Codex writes there is ignored.
    var codexSaid: [String: String] = [:]
    func codexMatters(_ path: String) -> Bool {
        guard (path as NSString).lastPathComponent.hasPrefix("rollout-"), path.hasSuffix(".jsonl") else { return false }   // its database and other files
        guard let h = FileHandle(forReadingAtPath: path) else { return codexSaid.removeValue(forKey: path) != nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 8192 ? size - 8192 : 0)
        let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        let kinds = ["task_started", "task_complete", "turn_aborted", "user_message", "exec_approval_request", "apply_patch_approval_request"]
        let last = tail.split(separator: "\n").reversed().compactMap { line in kinds.first { line.contains("\"\($0)\"") } }.first ?? ""
        if codexSaid[path] == last { return false }
        codexSaid[path] = last
        return true
    }
    /// What each session file last said that the interface shows: its state, what it waits for, and its name.
    var said: [String: String] = [:]
    /// True if this changed file means the list needs reloading.
    func matters(_ path: String) -> Bool {
        if path.contains("/.codex/") { return codexMatters(path) }
        guard path.contains("/.claude/sessions/"), path.hasSuffix(".json") else { return true }   // the helper's note, or anything unexpected
        guard let data = FileManager.default.contents(atPath: path), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return said.removeValue(forKey: path) != nil || !FileManager.default.fileExists(atPath: path)   // gone, or half-written
        }
        let now = "\(o["status"] ?? "")|\(o["waitingFor"] ?? "")|\(o["name"] ?? "")|\(o["statusUpdatedAt"] ?? "")"
        if said[path] == now { return false }
        said[path] = now
        return true
    }
    /// Every three seconds: reload if something changed, or if it has been a while (Codex sessions and processes
    /// that ended are not reported). Otherwise just redraw what is on screen so the times keep counting.
    func tick() {
        let now = Date().timeIntervalSince1970
        if changed || now - lastLoad >= 12 { refresh() }
        else if model.open || widget?.isVisible == true { model.objectWillChange.send() }
    }
    func refresh() {
        changed = false; lastLoad = Date().timeIntervalSince1970
        if Demo.on {
            let s = Labels.apply(Demo.sessions())
            model.sessions = s; model.recent = Prefs.bool("showRecent") ? Labels.apply(Demo.closed()) : []
            // The session you are in: the last sample session you went to, or to begin with the one working on search.
            model.currentId = s.first { $0.id == (Demo.here ?? "d2") }?.id
            if model.open && !movedSelection && model.query.isEmpty { model.selected = model.filtered.firstIndex { $0.id == model.currentId } ?? -1 }
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path
        queue.async {
            let hide = Prefs.hiddenRepos
            let s = Labels.apply(Loader.load().filter { !hide.contains($0.project.lowercased()) })
            let past = Labels.apply((Prefs.bool("showRecent") ? Loader.recent(excluding: Set(s.map(\.id))) : []).filter { !hide.contains($0.project.lowercased()) })
            let here = Loader.currentSession(among: s)
            // Having a session's terminal in front counts as having seen it, but only while its editor is the app
            // you are actually in. If you start something and switch to a browser, it should still turn green
            // when it finishes: you were not looking.
            if let here, let pid = s.first(where: { $0.id == here })?.pid, let front, Loader.owner(of: pid).app == front {
                Seen.at[here] = Date().timeIntervalSince1970 * 1000
            }
            DispatchQueue.main.async {
                // Only hand the interface new data when something is different, so an unchanged list is not redrawn.
                if self.model.sessions != s { self.model.sessions = s }
                if self.model.recent != past { self.model.recent = past }
                if self.model.currentId != here { self.model.currentId = here }
                // Keep the highlight on the session you are in as fresh data arrives, until you move it yourself.
                if self.model.open && !self.movedSelection && self.model.query.isEmpty {
                    self.model.selected = self.model.filtered.firstIndex { $0.id == here } ?? -1
                }
            }
        }
    }

    /// Top centre of the screen. The window is always panel-sized; it is only on screen while open or animating.
    /// A small orb just left of the notch while the panel is closed: turning if a session is working, amber if
    /// one needs you, green if one just finished, and absent when nothing is going on. Clicks pass straight through it.
    /// The app has no Dock icon and so shows no menu bar of its own, but the keys still go through a menu: without one,
    /// Command-Q does nothing in the settings window or the dashboard, and neither do copy and paste in a text field.
    func setUpMenu() { NSApp.mainMenu = Self.menu() }
    static func menu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(NSMenuItem(title: "Settings…", action: #selector(AppDelegate.openSettingsFromMenu), keyEquivalent: ","))
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Quit codehatch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = app
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        return main
    }
    @objc func openSettingsFromMenu() { showSettings() }

    /// Opening codehatch again while it is already running (from Applications, Spotlight or Launchpad) shows the
    /// panel, so there is always a visible answer to "is it running?". It has no Dock icon to click instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DispatchQueue.main.async { self.open(byHover: false) }
        return false
    }

    /// macOS would not let codehatch control Terminal or iTerm2. Say so once per app per launch, with the way to fix it.
    var toldDenied = Set<String>()
    func automationDenied(_ app: String) {
        guard !toldDenied.contains(app), CommandLine.arguments.firstIndex(of: "--focus-terminal") == nil else { return }
        toldDenied.insert(app)
        close()
        let alert = NSAlert()
        alert.messageText = "codehatch isn't allowed to control \(app)"
        alert.informativeText = "To bring the right \(app) tab to the front, codehatch needs your permission. Turn on \(app) under codehatch in System Settings › Privacy & Security › Automation. Your sessions still show in the list without it."
        alert.addButton(withTitle: "Open System Settings"); alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The codehatch mark in the menu bar, the usual home for a utility like this: click it for the panel and the
    /// window, settings, and quitting. It can be hidden in settings.
    var statusItem: NSStatusItem?
    func setUpStatusItem() {
        guard Prefs.bool("showMenuIcon") else { statusItem.map { NSStatusBar.system.removeStatusItem($0) }; statusItem = nil; return }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let url = Bundle.main.url(forResource: "portal", withExtension: "png"), let mark = NSImage(contentsOf: url) {
            mark.size = NSSize(width: 16, height: 16); mark.isTemplate = true   // drawn in the menu bar's own colour
            item.button?.image = mark
        } else { item.button?.title = "ch" }
        item.button?.toolTip = "codehatch"
        // Clicking it opens a small panel of our own, like Wi-Fi's and Sound's, rather than a classic menu: on macOS 26
        // a classic menu bar menu draws its highlight late (a known Apple bug, see the Apple developer forums thread
        // "Incorrect menu consistency warnings logged in Tahoe for NSStatusItem").
        item.button?.target = self
        item.button?.action = #selector(toggleMenuPanel)
        statusItem = item
    }
    @objc func menuShowPanel() { DispatchQueue.main.async { self.open(byHover: false) } }
    var menuPanel: NSPanel?
    @objc func toggleMenuPanel() {
        if let p = menuPanel, p.isVisible { closeMenuPanel(); return }
        guard let button = statusItem?.button, let bw = button.window else { return }
        let size = NSSize(width: 240, height: 182)
        let p = menuPanel ?? {
            let p = KeyPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = NSColor(white: 0, alpha: 0.001); p.hasShadow = true
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            p.acceptsMouseMovedEvents = true   // so pointer movements over it reach codehatch, for the hover
            p.contentView = FirstClickHost(rootView: AnyView(MenuPanel(app: self).environmentObject(PointerTracker.menu)))
            menuPanel = p
            return p
        }()
        let screen = bw.screen ?? NSScreen.main ?? self.screen
        var x = bw.frame.minX - 6
        x = min(max(x, screen.visibleFrame.minX + 6), screen.visibleFrame.maxX - size.width - 6)
        p.setFrame(NSRect(x: x, y: bw.frame.minY - size.height - 6, width: size.width, height: size.height), display: true)
        p.makeKeyAndOrderFront(nil)
        button.highlight(true)
    }
    func closeMenuPanel() {
        menuPanel?.orderOut(nil)
        statusItem?.button?.highlight(false)
        PointerTracker.menu.pointer(at: nil)
    }
    /// A choice in the menu bar panel: close the panel, then do it.
    func menuChose(_ what: String) {
        closeMenuPanel()
        switch what {
        case "sessions": menuShowPanel()
        case "window": toggleWidget()
        case "settings": showSettings()
        case "updates": updater.checkForUpdates(nil)
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }
    @objc func menuToggleWindow() { toggleWidget() }
    @objc func menuCheckUpdates() { updater.checkForUpdates(nil) }
    var beacon: NSPanel!
    /// Sparkle. It looks at the feed on codehatch.ai about once a day, and when there is a newer version, checks its
    /// signature against the key in Info.plist, offers it, and installs it. Not started in the tests or the demo.
    lazy var updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    func setUpBeacon() {
        beacon = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        beacon.isOpaque = false; beacon.backgroundColor = .clear; beacon.hasShadow = false
        // One level below the panel, so the open panel always covers it. At the same level, macOS could put either in
        // front while redrawing, for example while swiping between desktops, and the orb showed through the panel.
        beacon.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        beacon.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Only the black tab takes clicks; the clear space around it lets them through to the menu bar.
        beacon.contentView = FirstClickHost(rootView: Beacon(model: model) { [weak self] in self?.beaconClicked() })
        placeBeacon()
        beacon.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.placeBeacon() }
    }
    /// Clicking the tab: a finished session is marked as seen, which clears it (the next most urgent thing, if any,
    /// takes its place). Anything else opens the panel.
    func beaconClicked() {
        if let s = model.spotlight, s.rank == 1 {
            Seen.at[s.id] = Date().timeIntervalSince1970 * 1000
            model.objectWillChange.send()   // "seen" is not part of a session's data, so say plainly that the picture changed
            refresh()
        } else {
            open(byHover: false)
        }
    }
    func placeBeacon() {
        // Always on the built-in display's notch if there is one, otherwise top centre of the main screen.
        let s = NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main ?? screen
        let bar = max(24, s.frame.maxY - s.visibleFrame.maxY)
        var notch: CGFloat = 0
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea { notch = max(0, s.frame.width - l.width - r.width) }
        // At least as tall as the notch, and the menu bar's height where that is taller (here the notch measures 33
        // points and the menu bar 34). The black is drawn right across the notch, so its bottom edge is the only one
        // that shows; were it shorter than the real notch, the notch's own edge would show a point lower beside it.
        let height = max(s.safeAreaInsets.top, bar)
        model.beaconNotch = notch
        beacon.setFrame(NSRect(x: s.frame.midX - notch / 2 - 200 - TabShape.flare, y: s.frame.maxY - height, width: 200 + TabShape.flare + notch, height: height), display: true)
    }
    func place() {
        let bar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        var notch: CGFloat = 0
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea { notch = max(0, screen.frame.width - l.width - r.width) }
        model.barHeight = bar; model.notchWidth = notch
        model.notchHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : bar
        let size = NSSize(width: RootView.openWidth, height: RootView.openHeight)
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    /// In Terminal and iTerm2 nothing reports which tab you are in, the way the editor helper does. So when the panel
    /// opens while one of them is the app in front, ask it which tab that is, and note the session running there in
    /// the same place the helper would. The highlight then lands on it a moment later.
    func noteTerminalInFront() {
        guard !Demo.on, let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path, let kind = Terminals.kind(front) else { return }
        let sessions = model.sessions
        queue.async {
            guard let tty = Terminals.frontTTY(kind), let s = sessions.first(where: { $0.pid > 1 && Terminals.tty(of: $0.pid) == tty }) else { return }
            let dir = Loader.home.appendingPathComponent(".codehatch")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let note: [String: Any] = ["pid": Int(s.pid), "folder": s.cwd, "at": Date().timeIntervalSince1970 * 1000]
            if let data = try? JSONSerialization.data(withJSONObject: note) { try? data.write(to: dir.appendingPathComponent("active-terminal.json"), options: .atomic) }
        }
    }
    var movedSelection = false   // you have moved the highlight with the arrow keys since the panel opened
    // The panel opens and closes on the timing most notch apps share:
    // a spring of 0.42 to open, and a slightly slower one to close. Theirs opens with a little give (damping 0.8), which
    // sends the panel about seven points past full size before it settles back; on a panel with a crisp edge that reads
    // as growing too far and shrinking. Ours is damped until that is too small to see.
    func open(byHover: Bool) {
        if !model.open { movedSelection = false; model.repoFilter = nil }
        noteTerminalInFront()
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
        DispatchQueue.main.async { withAnimation(.spring(response: 0.42, dampingFraction: 0.92)) { self.model.open = true } }
    }
    func close() {
        guard model.open else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) { model.open = false }
        // The window leaves the screen only once the shape has finished shrinking into the notch. The closing spring
        // takes about 0.7s to settle; taken away sooner, the last sliver of the panel was cut off mid-move.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { if !self.model.open { self.panel.orderOut(nil) } }
    }
    /// Pushing the pointer into the top centre of the screen opens the panel; moving away from it closes it again.
    var peeking = false
    func trackMouse() {
        if !model.open {
            // Open once the pointer has rested in the notch for a tenth of a second, so brushing past does not open it.
            guard Prefs.bool("openOnHover"), pointerInNotch() else { hoverTimer?.invalidate(); hoverTimer = nil; return }
            guard hoverTimer == nil else { return }
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.hoverTimer = nil
                if !self.model.open, self.pointerInNotch() { self.open(byHover: true) }
            }
        } else if byHover, !peeking, !panel.frame.insetBy(dx: -24, dy: -24).contains(NSEvent.mouseLocation) {
            close()
        }
    }

    func toggle() { model.open ? close() : open(byHover: false) }

    /// A second copy of the list in an ordinary Mac window that stays on screen: the usual close, minimise and
    /// full-screen buttons, draggable to any display, resizable, and it remembers where it was.
    var widget: NSWindow?
    /// The stay-on-screen window follows the Mac's light or dark setting, or is held to one, as chosen in settings.
    func applyWindowLook(to w: NSWindow? = nil) {
        guard let w = w ?? widget else { return }
        switch Prefs.string("windowLook") {
        case "light": w.appearance = NSAppearance(named: .aqua)
        case "dark": w.appearance = NSAppearance(named: .darkAqua)
        default: w.appearance = nil
        }
    }
    static let widgetMin = NSSize(width: 440, height: 320)
    // The window's own minimum size does not survive SwiftUI hosting, so the limit is enforced as it is dragged.
    func windowWillResize(_ sender: NSWindow, to size: NSSize) -> NSSize {
        NSSize(width: max(size.width, Self.widgetMin.width), height: max(size.height, Self.widgetMin.height))
    }
    func toggleWidget() {
        // Already open: bring it forward rather than closing it. It is often behind other windows, minimised or on
        // another screen, so closing it made the first click look like it did nothing and needed a second one.
        if let w = widget {
            close()
            if w.isMiniaturized { w.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        // The notch panel closes first. The window shares its model, so a window made before that would have caught the
        // panel's closing animation and slid its contents about as it appeared.
        close()
        let s = NSScreen.screens.last ?? screen
        let w = NSWindow(contentRect: NSRect(x: s.visibleFrame.maxX - 1200, y: s.visibleFrame.maxY - 720, width: 1180, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.title = "codehatch"
        applyWindowLook(to: w)
        w.isOpaque = false; w.backgroundColor = NSColor(white: 0, alpha: 0.001)   // not .clear: see the panel's note on hover
        w.isMovableByWindowBackground = true
        w.acceptsMouseMovedEvents = true   // pointer movements over it reach codehatch, for the hover
        w.isReleasedWhenClosed = false
        w.level = Prefs.bool("widgetOnTop") ? .floating : .normal
        w.collectionBehavior = [.fullScreenPrimary]
        w.animationBehavior = .none   // it simply appears, like any window being opened
        w.contentMinSize = NSSize(width: 440, height: 320)
        w.delegate = self
        // Its last size and place are restored before anything is drawn in it, so it is laid out once, at its real size,
        // instead of being drawn small and then stretched (which reflowed every row and card as it opened).
        w.setFrameAutosaveName("codehatchWidget")
        let host = FirstClickHost(rootView: AnyView(RootView(model: model, app: self, detached: true).environmentObject(PointerTracker.window)))
        // Otherwise SwiftUI replaces the window's minimum size with the content's own, which is far too small.
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: w.contentLayoutRect.size)
        w.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in self?.widget = nil }
        widget = w
        var still = Transaction(); still.disablesAnimations = true
        withTransaction(still) { host.layoutSubtreeIfNeeded() }
        w.orderFrontRegardless()
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
    /// Ask for a new name for a session and remember it. An empty name goes back to the session's own title.
    func rename(_ s: Session) {
        close()
        let alert = NSAlert()
        alert.messageText = "Rename session"
        alert.informativeText = "This name is shown in codehatch only. Leave it empty to go back to the session's own title."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = s.title; field.placeholderString = "Session name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = Labels.all
        if name.isEmpty { names.removeValue(forKey: s.id) } else { names[s.id] = name }
        Labels.all = names
        refresh()
    }
    /// Close a session from the panel or the window.
    /// Close a session from a right-click. A session that is working or waiting on you is closed only after asking, if
    /// that setting is on (it is by default); anything else closes straight away.
    func askToEnd(_ s: Session) {
        if Prefs.bool("confirmClose"), s.rank == 0 || s.rank == 2 {
            close()
            let alert = NSAlert()
            alert.messageText = "Close “\(s.title)”?"
            alert.informativeText = s.rank == 2 ? "It is still working. Closing it stops it, and closes the terminal it runs in." : "It is waiting on you. Closing it stops it, and closes the terminal it runs in."
            alert.addButton(withTitle: "Close Session"); alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        end(s)
    }
    func end(_ s: Session) {
        if Demo.on {   // a sample session just leaves the list
            Demo.hidden.insert(s.id)
            withAnimation(.easeInOut(duration: 0.2)) { model.closed = (s.title, "claude --resume sample", nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { withAnimation { self.model.closed = nil } }
            refresh(); return
        }
        dbg("end: \(s.title) pid \(s.pid)")
        // What is left once it is closed: the same conversation, marked closed, which Reopen can bring back.
        var after = Session(id: s.id, pid: 0, cwd: s.cwd, status: "closed", updatedAt: Date().timeIntervalSince1970 * 1000, title: s.title)
        after.tool = s.tool; after.branch = s.branch; after.lastAsked = s.lastAsked; after.lastReply = s.lastReply; after.replyIsNewer = s.replyIsNewer; after.recap = s.recap
        withAnimation(.easeInOut(duration: 0.2)) { model.closed = s.empty ? nil : (s.title, s.resumeCommand, after) }
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
            if let pick = Terminals.paths[Prefs.string("reopenIn")] { app = pick; scheme = Prefs.string("reopenIn") }
            if let app, let kind = Terminals.kind(app), FileManager.default.fileExists(atPath: app) {
                Terminals.run(kind, in: s.cwd, command: s.resumeCommand)
                Loader.recentCache.at = 0; self.refresh()
                return
            }
            guard let app, let scheme else {
                // No editor with the helper: leave the command on the clipboard to paste into any terminal.
                DispatchQueue.main.async { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("cd \"\(s.cwd)\" && \(s.resumeCommand)", forType: .string); NSSound.beep() }
                return
            }
            run(["-a", app, s.cwd])
            var q = URLComponents(); q.queryItems = [URLQueryItem(name: "tool", value: s.tool), URLQueryItem(name: "id", value: s.id.replacingOccurrences(of: "codex-", with: "")), URLQueryItem(name: "cwd", value: s.cwd)]
            let link = "\(scheme)://codehatch.codehatch-helper/resume?" + (q.percentEncodedQuery ?? "")
            // Sent several times: the window may still be opening. The helper acts on the first one that reaches the
            // right window and ignores the rest.
            var last = 0.0
            for at in [0.6, 1.5, 3.5, 7.0] { Thread.sleep(forTimeInterval: at - last); last = at; run(["-g", link]) }
            Loader.recentCache.at = 0
            self.refresh()
        }
    }
    func go(_ s: Session) {
        if Demo.on {
            // For recording: if there is a made-up project of the same name in ~/codehatch-demo, bring its editor
            // window to the front, so picking a sample session lands somewhere as a real one would; and from then
            // on it is the session you are in, highlighted as such.
            Demo.here = s.id; refresh()
            close()
            let folder = NSHomeDirectory() + "/codehatch-demo/" + s.project
            if FileManager.default.fileExists(atPath: folder) {
                let editor = UserDefaults.standard.string(forKey: "lastEditorApp") ?? "/Applications/Cursor.app"
                queue.async { _ = Codex.shell("/usr/bin/open", ["-a", editor, folder]) }
            }
            return
        }
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
            if let kind = Terminals.kind(app) {
                UserDefaults.standard.set(app, forKey: "lastEditorApp"); UserDefaults.standard.set(kind, forKey: "lastEditorScheme")
                // The exact tab, by the terminal device the session runs on; failing that, just the app.
                if let tty = Terminals.tty(of: s.pid), Terminals.focus(kind, tty: tty) { return }
                run(["-a", app]); return
            }
            guard let scheme = editors[name] else { run(["-a", app]); return }
            UserDefaults.standard.set(app, forKey: "lastEditorApp"); UserDefaults.standard.set(scheme, forKey: "lastEditorScheme")
            run(["-a", app, s.cwd])
            // Then ask the helper inside the editor (if installed) to show the terminal tab this session is running in.
            // Sent twice, because the first can arrive before the right window has come forward.
            // A session in the extension's chat panel has no terminal tab: ask the helper to bring the panel forward.
            var panel = URLComponents(); panel.queryItems = [URLQueryItem(name: "cwd", value: s.cwd)]
            let link = s.inPanel
                ? "\(scheme)://codehatch.codehatch-helper/panel?" + (panel.percentEncodedQuery ?? "")
                : "\(scheme)://codehatch.codehatch-helper/focus?pids=" + chain.map(String.init).joined(separator: ",")
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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "codehatch settings"; w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView(app: self))
        w.center(); settingsWindow = w; w.orderFrontRegardless()
    }
    var setupWindow: NSWindow?
    /// The welcome window. Shown once, the first time the app runs; also reachable from settings.
    func showSetup() {
        if setupWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Welcome to codehatch"; w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SetupView { [weak self] in
                UserDefaults.standard.set(true, forKey: "didSetup")
                self?.setupWindow?.close(); self?.setupWindow = nil
                self?.refresh()
            })
            w.center(); setupWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }
    var settingsWindow: NSWindow?
    func showSettings() {
        close()
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "codehatch settings"; w.isReleasedWhenClosed = false
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
