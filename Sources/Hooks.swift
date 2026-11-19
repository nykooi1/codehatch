import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

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
            } else if e.tool == "claude", let sid = e.sessionId, !sid.hasPrefix("pid-"), !Loader.background.contains(sid), let cwd = e.cwd, e.pid > 1, kill(e.pid, 0) == 0 {
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
