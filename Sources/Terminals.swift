import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

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
