import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

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
        case "setup-done": size = CGSize(width: 470, height: 560); view = AnyView(SetupView(done: {}, results: [("Live updates", nil), ("Helper for Cursor", nil), ("Helper for VS Code", nil), ("Open at login", nil)]))
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
