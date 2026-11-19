// codehatch: a Mac app that keeps every Claude Code and Codex session one click away, under the notch.
// This file only starts the app; each part lives in its own file beside it.
import AppKit

let app = NSApplication.shared

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
