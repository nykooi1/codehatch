import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

// ── reading Claude Code's own files (read-only) ──
enum Loader {
    /// The home folder everything is read from. Tests point CODEHATCH_HOME at a stand-in folder, so they can lay out
    /// pretend session files without going near the real ones.
    static let home: URL = ProcessInfo.processInfo.environment["CODEHATCH_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
    static var titleCache: [String: (size: UInt64, title: String?)] = [:]

    /// Sessions Claude Code runs in the background (a fork, for one): no terminal or editor shows them, so there is
    /// nowhere to take you, and they are left out. Kept so the hooks do not add them back.
    static var background: Set<String> = []

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
            if (o["kind"] as? String) == "bg" { background.insert(sid); continue }
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
