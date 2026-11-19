import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

/// Lays its pieces out left to right and starts a new line when the next one will not fit.
struct Wrap: Layout {
    var spacing: CGFloat = 6
    func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]], x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > width, !rows[rows.count - 1].isEmpty { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, size)); x += size.width + spacing
        }
        return rows.map { $0.map { (index: $0.0, size: $0.1) } }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600, lines = rows(subviews, width: width)
        let height = lines.map { $0.map(\.size.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            let tall = line.map(\.size.height).max() ?? 0
            for item in line {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (tall - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += tall + spacing
        }
    }
}

/// Everything codehatch adds outside itself, in one place: the hooks and the editor helper. Run once from the welcome
/// window, and again from settings whenever asked.
enum Setup {
    /// Each thing set up and how it went: nil is fine, otherwise what went wrong.
    static func run(hooks: Bool, editors: [String]) -> [(what: String, problem: String?)] {
        var out: [(what: String, problem: String?)] = []
        if hooks {
            let problem = Hooks.set(true)
            if problem == nil { UserDefaults.standard.set(true, forKey: "liveUpdates") }
            out.append(("Live updates", problem))
        }
        for e in Helper.editors where editors.contains(e.id) { out.append(("Helper for " + e.label, Helper.install(e))) }
        return out
    }
    /// Whether the welcome window should appear: not yet shown, and there is something it could set up.
    static var wanted: Bool { !Prefs.bool("didSetup") && !Demo.on && ProcessInfo.processInfo.environment["CODEHATCH_HOME"] == nil }
}

/// The welcome window: what codehatch would like to add, said plainly, with one button to add it.
struct SetupView: View {
    var done: () -> Void
    @State private var hooks = true
    @State private var atLogin = true
    @State private var editors: Set<String> = Set(Helper.present.map(\.id))
    @State private var results: [(what: String, problem: String?)]? = nil
    init(done: @escaping () -> Void, results: [(what: String, problem: String?)]? = nil) {
        self.done = done; _results = State(initialValue: results)   // results given only to draw the finished screen in tests
    }
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The mark on a plain black square, drawn here rather than taken from the app icon: macOS 26 gives app icons
            // a glassy light rim, which looked like a white border at this size.
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black)
                if let url = Bundle.main.url(forResource: "portal", withExtension: "png"), let mark = NSImage(contentsOf: url) {
                    Image(nsImage: mark).resizable().interpolation(.high).frame(width: 28, height: 28)
                }
            }
            .frame(width: 52, height: 52)
            Text("Set up codehatch").font(.system(size: 20, weight: .semibold))
            Text("codehatch works best with two small additions. Both are plain files you can read, both can be removed in settings, and neither sends anything anywhere.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let results {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: r.problem == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(r.problem == nil ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.what)
                                if let p = r.problem { Text(p).font(.callout).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                // What is left to do, where it cannot be missed: a box of its own, in full-size text that wraps, not a
                // grey footnote. Without the Codex step, Codex sessions never update live, and nothing else says why.
                let codexStep = Hooks.hasCodex && hooks, editorStep = !editors.isEmpty
                if codexStep || editorStep {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(codexStep && editorStep ? "Two more things" : "One more thing").font(.system(size: 13, weight: .semibold))
                        if codexStep {
                            nextStep("In Codex, type /hooks once and approve them",
                                     "Codex asks before it runs new hooks. Until you approve codehatch's, Codex sessions won't update live. Sessions that were already open need a restart.")
                        }
                        if editorStep {
                            nextStep("Allow the link in your editor",
                                     "The first time you jump to a session, VS Code or Cursor asks whether codehatch's helper may open a link. Tick Don't ask again, then Open.")
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.45), lineWidth: 1))
                }
                HStack { Spacer(); Button("Done") { done() }.keyboardShortcut(.defaultAction) }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $hooks) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Live updates").font(.system(size: 13, weight: .medium))
                            Text("Adds a small script to Claude Code" + (Hooks.hasCodex ? " and Codex" : "") + " so they tell codehatch the moment a session starts, stops or needs you. It records the event only, never your prompts. A copy of each settings file is saved first.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Toggle(isOn: $atLogin) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open at login").font(.system(size: 13, weight: .medium))
                            Text("So it is there after you restart your Mac.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Helper.present, id: \.id) { e in
                        Toggle(isOn: Binding(get: { editors.contains(e.id) }, set: { on in if on { editors.insert(e.id) } else { editors.remove(e.id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Helper for \(e.label)" + (Helper.installed(e) ? " (already installed)" : "")).font(.system(size: 13, weight: .medium))
                                Text("A small extension that lets codehatch land on the exact terminal tab in \(e.label) and reopen a closed session in the right project.")
                                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if Helper.present.isEmpty { Text("No editor built on VS Code was found, so there is no helper to install. Terminal and iTerm2 need none.").font(.callout).foregroundStyle(.secondary) }
                }
                .toggleStyle(.checkbox)
                HStack {
                    Button("Not now") { done() }
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button("Set up") {
                        working = true
                        let wantHooks = hooks, wantEditors = Array(editors), wantLogin = atLogin
                        DispatchQueue.global().async {
                            var r = Setup.run(hooks: wantHooks, editors: wantEditors)
                            if wantLogin { r.append(("Open at login", LoginItem.set(true))) }
                            DispatchQueue.main.async { results = r; working = false }
                        }
                    }
                    .keyboardShortcut(.defaultAction).disabled(working || (!hooks && !atLogin && editors.isEmpty))
                }
            }
        }
        .padding(22).frame(width: 470)
    }
    /// One thing left to do after setup: what to do, in bold, then why, both wrapping onto as many lines as they need.
    func nextStep(_ title: String, _ why: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.right.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(why).font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Opening codehatch when you log in, through the Mac's own login items (System Settings › General › Login Items).
enum LoginItem {
    static var on: Bool { SMAppService.mainApp.status == .enabled }
    /// Returns nil when it worked, or what went wrong.
    @discardableResult static func set(_ wanted: Bool) -> String? {
        do {
            if wanted { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
            else if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            dbg("login item: \(error)")
            return "macOS would not change this. You can add codehatch in System Settings › General › Login Items."
        }
    }
}
