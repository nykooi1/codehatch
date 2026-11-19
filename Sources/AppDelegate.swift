import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

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
        // One window for the notch, always on screen, the usual way for a notch app: the tab with
        // the orb is drawn in it, over the panel, and the panel grows out of the notch and the tab together and shrinks
        // back into them. While it is closed the window lets every click through to the menu bar (the clicks on the tab
        // are caught by the click listener below).
        panel.contentView = FirstClickHost(rootView: ZStack(alignment: .top) {
            RootView(model: model, app: self).environmentObject(PointerTracker.panel)
            NotchTab(model: model)   // on top: closed, the panel's black is the tab's background (hidden while open)
        })
        panel.ignoresMouseEvents = true
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.model.open else { return }
            self.screen = AppDelegate.notchScreen(); self.place()
        }
        setUpMenu()
        setUpStatusItem()
        if Setup.wanted || CommandLine.arguments.contains("--setup") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.showSetup() } }
        if !Demo.on, ProcessInfo.processInfo.environment["CODEHATCH_HOME"] == nil { updater.startUpdater() }
        screen = AppDelegate.notchScreen()
        place()
        panel.orderFrontRegardless()   // closed, it is just the notch (and the tab beside it when something is going on)
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
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            if let self, !self.model.open, e.type == .leftMouseDown, self.tabRect().contains(NSEvent.mouseLocation) { self.beaconClicked(); return }
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
    /// The Codex sessions hooks have spoken about, by their file in ~/.codehatch/live.
    var codexHeard: Set<String> = []
    /// True if this changed file means the list needs reloading.
    func matters(_ path: String) -> Bool {
        // The first hook event of a Codex session is a session codehatch may not have found yet: hooks only update the
        // Codex sessions it has found, so list the Codex programs afresh on this reload instead of using a list up to
        // ten seconds old. Later events from the same session change nothing here.
        if path.contains("/.codehatch/live/codex-"), !codexHeard.contains(path) {
            codexHeard.insert(path)
            queue.async { Codex.runningCache.at = 0 }
        }
        if path.contains("/.codex/") {
            let changed = codexMatters(path)
            // A log codehatch has not matched to a session yet is a session it may not know about, started since it
            // last listed the Codex programs: list them afresh on this reload, rather than using a list up to ten
            // seconds old, so a new Codex session shows up straight away even without hooks. (On the same queue as
            // the reload, which reads these, and ahead of it.)
            if changed { queue.async { if !Codex.logOf.values.contains(path) { Codex.runningCache.at = 0 } } }
            return changed
        }
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
            model.currentId = Demo.here.flatMap { h in s.first { $0.id == h }?.id }   // none until you open one
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
        p.setFrame(NSRect(x: x, y: bw.frame.minY - size.height - 1, width: size.width, height: size.height), display: true)
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
    /// Sparkle. It looks at the feed on codehatch.ai about once a day, and when there is a newer version, checks its
    /// signature against the key in Info.plist, offers it, and installs it. Not started in the tests or the demo.
    lazy var updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    /// The display with the notch, or the main one.
    static func notchScreen() -> NSScreen {
        NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main ?? NSScreen.screens[0]
    }
    /// Where the tab with the orb is on screen, left of the notch: the part that takes a click while the notch is closed.
    func tabRect() -> CGRect {
        guard model.tabWidth > 0, panel.isVisible else { return .zero }
        let right = panel.frame.midX - model.beaconNotch / 2
        let h = model.notchHeight > 0 ? model.notchHeight : model.barHeight
        let left = panel.frame.midX + model.beaconNotch / 2 - model.tabWidth + TabShape.flare
        return CGRect(x: left, y: panel.frame.maxY - h, width: max(0, right - left), height: h)
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
    func place() {
        let bar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        var notch: CGFloat = 0
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea { notch = max(0, screen.frame.width - l.width - r.width) }
        model.barHeight = bar; model.notchWidth = notch; model.beaconNotch = notch
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
        panel.ignoresMouseEvents = false
        if peeking { panel.orderFrontRegardless() } else { panel.makeKeyAndOrderFront(nil) }
        DispatchQueue.main.async { withAnimation(.spring(response: 0.42, dampingFraction: 0.92)) { self.model.open = true } }
    }
    func close() {
        guard model.open else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) { model.open = false }   // the usual notch close
        // The window stays on screen, as the notch, but lets clicks through again and gives the keyboard back to the app
        // you were in (asking that app to take it back does not work; this does).
        panel.ignoresMouseEvents = true
        if panel.isKeyWindow { NSApp.deactivate() }
        // Opened on another display, it goes back to the notch once it has finished closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard !self.model.open, self.screen != AppDelegate.notchScreen() else { return }
            self.screen = AppDelegate.notchScreen(); self.place()
        }
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
        // Focused as it opens, like any window you ask for; only put in front, the first click on it went to focusing it.
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
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
