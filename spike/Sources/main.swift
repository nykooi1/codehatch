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
    var recap: String? = nil    // where the session is: Claude Code's own saved recap, or failing that the last thing asked
    var branch: String? = nil
    /// Opened but never used: Claude Code has no title or history for it, only a placeholder name like "repo-e9".
    var empty = false
    var project: String { (cwd as NSString).lastPathComponent }
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
        case 3: return "idle"
        default: return waitingFor != nil ? "sitting on a start-up dialog" : "opened, never used"
        }
    }
    var seconds: Double { max(0, Date().timeIntervalSince1970 - updatedAt / 1000) }
    /// Worth showing in the resting pill: working right now, or started waiting on you within the last hour.
    var active: Bool { status == "busy" || (status == "waiting" && seconds < 3600) }
    var age: String {
        let s = seconds
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
            let ex = extras(for: sid, cwd: cwd); s.recap = ex.recap; s.branch = ex.branch
            out.append(s)
        }
        out += Codex.load()
        // Most recent activity first, and nothing else: a session only moves when something happens in it.
        return out.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
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
    static var extraCache: [String: (size: UInt64, recap: String?, branch: String?)] = [:]
    static func extras(for sid: String, cwd: String) -> (recap: String?, branch: String?) {
        let esc = cwd.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        let url = home.appendingPathComponent(".claude/projects/\(esc)/\(sid).jsonl")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? UInt64 else { return (nil, nil) }
        if let c = extraCache[sid], c.size == size { return (c.recap, c.branch) }
        var recap: String? = nil, branch: String? = nil
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            // Claude Code writes a short recap into the history when a session has been left for a few minutes.
            if let hit = lastLine(in: data, containing: "\"subtype\":\"away_summary\"") { recap = hit.obj["content"] as? String }
            if let r = data.range(of: Data("\"gitBranch\":\"".utf8), options: .backwards), let q = data[r.upperBound...].firstIndex(of: UInt8(ascii: "\"")) {
                branch = String(decoding: data[r.upperBound..<q], as: UTF8.self)
            }
            if recap == nil, let asked = lastPrompt(in: data) { recap = "Last asked: " + asked }
        }
        extraCache[sid] = (size, recap, branch)
        return (recap, branch)
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
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("[") else { continue }
            let one = t.split(separator: "\n").first.map(String.init) ?? t
            return one.count > 140 ? String(one.prefix(139)) + "…" : one
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
    @Published var currentId: String?   // the session you are in, when the editor helper can tell us
    @Published var notchWidth: CGFloat = 0
    @Published var barHeight: CGFloat = 26

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

// ── the interface ──
struct RootView: View {
    @ObservedObject var model: Model
    @ObservedObject var dictation: Dictation
    weak var app: AppDelegate?
    var detached = false   // true for the stay-on-screen window, false for the panel under the notch
    @FocusState private var searchFocused: Bool
    @State private var hovered: String?
    static let openWidth: CGFloat = 640, openHeight: CGFloat = 470

    // Closed, the black shape is exactly the notch (or nothing, on a screen without one), so it can't be seen.
    // Opening grows that shape outward and down while the contents fade in; closing runs it backwards.
    var body: some View { if detached { widgetBody } else { panelBody } }

    /// The stay-on-screen window: the same list on dark glass, draggable to any display and resizable.
    var widgetBody: some View {
        VStack(spacing: 0) {
            // Starts to the right of the window's close, minimise and full-screen buttons.
            HStack(spacing: 8) { dots; stats; Spacer() }.padding(.leading, 78).padding(.trailing, 16).frame(height: 30)
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ZStack { Rectangle().fill(.ultraThinMaterial); Color.black.opacity(0.45) }.environment(\.colorScheme, .dark))
        .ignoresSafeArea()
    }

    @ViewBuilder var panelBody: some View {
        let closedW: CGFloat = model.notchWidth > 0 ? model.notchWidth : 160
        let closedH: CGFloat = model.notchWidth > 0 ? model.barHeight : 0
        VStack(spacing: 0) {
            pill.frame(height: model.barHeight)
            list
        }
        .frame(width: Self.openWidth, height: Self.openHeight, alignment: .top)
        .opacity(model.open ? 1 : 0)
        .frame(width: model.open ? Self.openWidth : closedW, height: model.open ? Self.openHeight : closedH, alignment: .top)
        // Dark frosted glass: the system blur of whatever is behind, darkened, and solid black at the very top so it joins the notch.
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.42)
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
                Image(systemName: dictation.listening ? "mic.fill" : "mic").font(.system(size: 13))
                    .foregroundStyle(dictation.listening ? PortalMark.lavender : .white.opacity(0.45))
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture { dictation.toggle() }
                    .help("Speak your search")
                if !detached {
                    Image(systemName: "macwindow.on.rectangle").font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
                        .contentShape(Rectangle().inset(by: -6))
                        .onTapGesture { app?.toggleWidget() }
                        .help("Keep a copy on screen that you can move to another display")
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
            .onChange(of: model.open) { _, isOpen in searchFocused = isOpen }
            .onChange(of: model.query) { _, _ in model.selected = 0 }
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            GeometryReader { geo in
                let rows = model.filtered
                ScrollView {
                    if detached && geo.size.width >= 640 {
                        // Wide enough for a board: one card per repo, as many across as fit.
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 520), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                            ForEach(repos(in: rows), id: \.self) { name in
                                VStack(spacing: 2) {
                                    repoHeader(name, count: rows.filter { $0.project == name }.count).padding(.top, 2)
                                    ForEach(rows.filter { $0.project == name }) { s in row(s, selected: false) }
                                }
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.045)))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.06), lineWidth: 1))
                            }
                        }
                        .padding(14)
                    } else {
                        // Narrow: one column, repos one under another.
                        VStack(spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, s in
                                if i == 0 || rows[i - 1].project != s.project {
                                    repoHeader(s.project, count: rows.filter { $0.project == s.project }.count).padding(.top, i == 0 ? 4 : 14)
                                }
                                row(s, selected: i == model.selected && !detached)
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
            Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            Text("\(count)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.25))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.bottom, 3)
    }

    func row(_ s: Session, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Group {
                if s.rank == 2 { Orb() }
                else if s.rank == 0 { Orb(spinning: false) }
                else if s.rank == 1 { Orb(spinning: false, tint: Color(white: 0.85), glow: 0.5) }
                else { Orb(spinning: false, tint: Color(white: 0.55), size: 8, glow: 0).opacity(0.55) }
            }.frame(width: 12, height: 12).padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(s.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(s.empty ? 0.45 : 0.95)).lineLimit(1)
                    if model.mixed {
                        Text(s.tool == "codex" ? "Codex" : "Claude").font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(.white.opacity(0.09))).fixedSize()
                    }
                }
                (Text("\(s.statusText) \(s.age)" + (s.branch.map { "  ·  \($0)" } ?? "")) + Text(s.id == model.currentId ? "   you're here" : "").foregroundColor(PortalMark.lavender))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                // Where the session is. Shown in the stay-on-screen window, where there is room for it.
                if detached, let recap = s.recap {
                    Text(recap).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.66)).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(selected ? 0.11 : hovered == s.id ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = s.id; NSCursor.pointingHand.set() } else if hovered == s.id { hovered = nil; NSCursor.arrow.set() }
        }
        .modifier(PointerLink())
        .onTapGesture { dbg("row clicked: \(s.title)"); app?.go(s) }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
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
        queue.async {
            let s = Loader.load()
            let here = Loader.currentSession(among: s)
            if let here { Seen.at[here] = Date().timeIntervalSince1970 * 1000 }
            DispatchQueue.main.async { self.model.sessions = s; self.model.currentId = here; self.dictation.words = Array(Set(s.map(\.project) + s.map(\.title))) }
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

    func open(byHover: Bool) {
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
    func toggleWidget() {
        if let w = widget { w.close(); return }
        let s = NSScreen.screens.last ?? screen
        let w = NSWindow(contentRect: NSRect(x: s.visibleFrame.maxX - 420, y: s.visibleFrame.maxY - 600, width: 380, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.title = "fathomed"
        w.appearance = NSAppearance(named: .darkAqua)
        w.isOpaque = false; w.backgroundColor = .clear
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.collectionBehavior = [.fullScreenPrimary]
        w.minSize = NSSize(width: 280, height: 220)
        w.contentView = FirstClickHost(rootView: RootView(model: model, dictation: dictation, app: self, detached: true))
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
        case kVK_DownArrow: if n > 0 { model.selected = min(n - 1, model.selected + 1) }
        case kVK_UpArrow: model.selected = max(0, model.selected - 1)
        case kVK_Return: if model.selected >= 0 && model.selected < n { go(model.filtered[model.selected]) }
        default: return false   // everything else is typing, and goes to the search field
        }
        return true
    }

    /// Bring the window that holds this session to the front.
    func go(_ s: Session) {
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
            run(["-a", app, s.cwd])
            // Then ask the helper inside the editor (if installed) to show the terminal tab this session is running in.
            // Sent twice, because the first can arrive before the right window has come forward.
            let link = "\(scheme)://fathomed.fathomed-portal-helper/focus?pids=" + chain.map(String.init).joined(separator: ",")
            for delay in [0.35, 1.0] { Thread.sleep(forTimeInterval: delay); run(["-g", link]) }
        }
    }

    func registerHotKey() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { AppDelegate.shared.toggle() }
            return noErr
        }, 1, &type, nil, nil)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: OSType(0x46544850), id: 1), GetApplicationEventTarget(), 0, &hotKey)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
