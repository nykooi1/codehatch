import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

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
    @State private var newHidden = ""
    /// The hidden repos as a list, in the order they were added. Stored one per line (older copies used commas).
    var hiddenList: [String] {
        var out: [String] = []
        for part in hiddenRepos.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let name = part.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !out.contains(where: { $0.lowercased() == name.lowercased() }) { out.append(name) }
        }
        return out
    }
    func addHidden() {
        let name = newHidden.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        hiddenRepos = (hiddenList + [name]).joined(separator: "\n")   // a repeat is dropped by hiddenList
        newHidden = ""
    }
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
                    Text("Where each one ran").tag("auto")
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
                ForEach(hiddenList, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button { hiddenRepos = hiddenList.filter { $0 != name }.joined(separator: "\n") } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless).help("Show this repo again")
                    }
                }
                HStack {
                    TextField("Hide a repo", text: $newHidden, prompt: Text("Folder name, like client-site")).onSubmit(addHidden)
                    Button("Add", action: addHidden).disabled(newHidden.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { Text("Never show these repos") } footer: {
                Text("Sessions in these repo folders are left out everywhere, open or closed.")
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
