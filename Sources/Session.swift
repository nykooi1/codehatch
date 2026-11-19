import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

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
