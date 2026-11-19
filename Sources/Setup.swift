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
            Text("codehatch works best with two small additions. Both are plain files you can read, you can remove either later, and neither sends anything anywhere.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let results {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                        if r.what == "Live updates", r.problem == nil {
                            // Say plainly what works now: Claude Code needs nothing more; Codex needs its one approval.
                            // Each tool is named only if it has been used on this Mac.
                            if Hooks.hasClaude {
                                resultRow(.done, "Claude Code is ready", "Live updates are on for sessions you start from now on.")
                            }
                            if Hooks.hasCodex {
                                resultRow(.todo, "Codex: one step left", "In a Codex session, type /hooks and approve codehatch's. Codex asks before it runs new hooks.")
                            }
                        } else {
                            resultRow(r.problem == nil ? .done : .problem, r.what, r.problem)
                        }
                    }
                }
                .padding(.vertical, 4)
                // The rest is good to know rather than to do now: a quiet panel, in full-size text that wraps.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Good to know").font(.system(size: 13, weight: .semibold))
                    if !editors.isEmpty {
                        Text("The first time you jump to a session, VS Code or Cursor asks whether codehatch's helper may open a link. Tick Don't ask again, then Open.")
                            .font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Sessions that were already open show live updates once restarted.")
                        .font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
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
    enum Outcome { case done, todo, problem }
    /// One line of what setup did: a tick when it is done, an arrow when one step is left, a warning when it failed.
    func resultRow(_ o: Outcome, _ title: String, _ detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: o == .done ? "checkmark.circle.fill" : o == .todo ? "arrow.right.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(o == .done ? Color.green : o == .todo ? Color.accentColor : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
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
