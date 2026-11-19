import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

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
    /// The width of the tab with the orb, including the part over the notch (0 while it is not showing).
    @Published var tabWidth: CGFloat = 0
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
