import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

// ── the interface ──
struct RootView: View {
    @ObservedObject var model: Model
    weak var app: AppDelegate?
    var detached = false   // true for the stay-on-screen window, false for the panel under the notch
    @Environment(\.colorScheme) private var scheme
    /// The stay-on-screen window can be light; the panel under the notch is always dark, to join the notch.
    var lightLook: Bool { detached && scheme == .light }
    /// The colour of words and lines: white on dark, black on light.
    var ink: Color { lightLook ? .black : .white }
    /// The colour behind them.
    var paper: Color { lightLook ? .white : .black }
    var lav: Color { lightLook ? Color(red: 0.80, green: 0.42, blue: 0.02) : PortalMark.amber }
    var grn: Color { lightLook ? Color(red: 0.10, green: 0.58, blue: 0.32) : PortalMark.done }
    @FocusState private var searchFocused: Bool
    @State private var settled = false                // true a moment after the window first appears; nothing animates before
    @AppStorage("showLastMessage") private var showLast = true
    @AppStorage("notchOrder") private var notchOrder = "recent"
    private var byRepo: Bool { notchOrder == "repo" }
    /// Where the session you are in sits in the list as now filtered, or -1 (no highlight) if it is not showing.
    private var hereIndex: Int { model.filtered.firstIndex { $0.id == model.currentId } ?? -1 }
    @AppStorage("confirmClose") private var confirmBusy = true
    @State private var copied: String?                // the session whose resume command was just copied
    @State private var overX: String?                 // the row whose x the pointer is on
    static let showX = CommandLine.arguments.contains("--show-x")   // for screenshots: show every row's x
    @State private var confirmClose: String?          // the row whose x has been clicked once and is asking "Close?"
    @State private var showUnused: Set<String> = []   // groups whose never-used sessions are expanded
    @State private var collapsed: Set<String> = []    // groups folded shut
    @State private var openClosed: Set<String> = []   // repos whose recently closed sessions are unfolded; folded to begin with
    @State private var shutInSearch: Set<String> = [] // while searching they start unfolded instead; these are the ones folded by hand
    /// Whether a repo's fold inside "Recently closed" is open. Folded to begin with; while you search, the repos with
    /// matches are open so the results can be seen. Either way a click on the fold's heading flips it.
    func closedFoldOpen(_ name: String) -> Bool { model.query.isEmpty ? openClosed.contains(name) : !shutInSearch.contains(name) }
    @State private var detailId: String?              // the session shown in the detail pane: the one last clicked
    @State private var paneShown = false              // whether the window is wide enough to show the detail pane
    @AppStorage("widgetGroup") private var groupBy = "state"    // repo | state
    @AppStorage("widgetLayout") private var layout = "cards"    // list | cards
    @AppStorage("widgetFilter") private var filter = "all"     // all | active
    static let openWidth: CGFloat = 640, openHeight: CGFloat = 470

    // Closed, the black shape is exactly the notch (or nothing, on a screen without one), so it can't be seen.
    // Opening grows that shape outward and down while the contents fade in; closing runs it backwards.
    var body: some View { if detached { widgetBody } else { panelBody } }

    /// The stay-on-screen window. One aligned list, in the manner of an issue tracker: a slim header per group,
    /// one row per session with its facts in columns, and, when the window is wide, a pane on the right that
    /// shows everything about the session you are pointing at.
    var widgetBody: some View {
        GeometryReader { geo in
            let table = geo.size.width >= 620, wide = geo.size.width >= 1060
            let groups = sessionGroups()
            VStack(spacing: 0) {
                // Starts to the right of the window's close, minimise and full-screen buttons.
                // Centred in the title bar, clear of the close, minimise and full-screen buttons on the left.
                stats.frame(maxWidth: .infinity).padding(.horizontal, 78).frame(height: 30)
                searchRow
                toolbar(roomy: table)
                Rectangle().fill(ink.opacity(0.08)).frame(height: 1)
                HStack(spacing: 0) {
                    ScrollView {
                        // The group headers scroll with the list. Kept in place they needed a solid fill to hide the rows
                        // passing under them, and a solid fill looked different from the glass around it depending
                        // on whether the window was focused.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groups) { g in
                                Section(header: groupHeader(g)) {
                                    if !collapsed.contains(g.id), g.id == Self.closedGroup {
                                        // Recently closed: one fold per repo, shut to begin with; searching opens them all.
                                        ForEach(repos(in: g.items), id: \.self) { name in
                                            let mine = g.items.filter { $0.project == name }, open = closedFoldOpen(name)
                                            closedRepoHeader(name, count: mine.count, open: open).padding(.leading, 14)
                                            if open {
                                                if layout == "cards" {
                                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 420), spacing: 10)], alignment: .leading, spacing: 10) {
                                                        ForEach(mine) { s in sessionCard(s) }
                                                    }
                                                    .padding(.horizontal, 14).padding(.bottom, 10).padding(.top, 2)
                                                } else {
                                                    ForEach(mine) { s in sessionRow(s, table: table) }
                                                }
                                            }
                                        }
                                    } else if !collapsed.contains(g.id) {
                                        let cards = g.items + (showUnused.contains(g.id) ? g.unused : [])
                                        if layout == "cards", !cards.isEmpty {
                                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 420), spacing: 10)], alignment: .leading, spacing: 10) {
                                                ForEach(cards) { s in sessionCard(s) }
                                            }
                                            .padding(.horizontal, 14).padding(.vertical, 10)
                                        } else if layout != "cards" {
                                            ForEach(g.items) { s in sessionRow(s, table: table) }
                                        }
                                        if !g.unused.isEmpty {
                                            if layout != "cards", showUnused.contains(g.id) { ForEach(g.unused) { s in sessionRow(s, table: table) } }
                                            Text(showUnused.contains(g.id) ? "hide unused" : "\(g.unused.count) opened but never used")
                                                .font(.system(size: 11)).foregroundStyle(ink.opacity(0.3))
                                                .padding(.leading, layout == "cards" ? 16 : 44).padding(.vertical, layout == "cards" ? 8 : 6).frame(maxWidth: .infinity, alignment: .leading)
                                                .contentShape(Rectangle())
                                                .onTapGesture { toggle(&showUnused, g.id) }
                                        }
                                    }
                                }
                            }
                            if groups.isEmpty {
                                Text(model.query.isEmpty ? "Nothing here yet." : "No session matches that.")
                                    .font(.system(size: 12.5)).foregroundStyle(ink.opacity(0.4)).padding(24).frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.bottom, 14)
                        // When a session has activity it glides up to its new place, and the others slide to make room.
                        // Only once the window has settled. On first appearing, the list going from empty to full was itself
                        // "a change", and every row and card flew in from the corner.
                        .animation(settled ? .spring(response: 0.5, dampingFraction: 0.84) : nil, value: groups.flatMap { $0.items.map { $0.id } })
                    }
                    if wide {
                        Rectangle().fill(ink.opacity(0.08)).frame(width: 1)
                        detailPane.frame(width: 380)
                    }
                }
                .onAppear { paneShown = wide }
                .onChange(of: wide) { _, now in paneShown = now }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Which groups are folded is remembered, like the rest of the window's view choices. The first time, recently
        // closed sessions are folded away: they are there to resume from, not to read through every time.
        .onAppear {
            var quiet = Transaction(); quiet.disablesAnimations = true
            withTransaction(quiet) { collapsed = Set(UserDefaults.standard.stringArray(forKey: "widgetFolded") ?? [Self.closedGroup]) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled = true }
        }
        .onChange(of: collapsed) { _, now in UserDefaults.standard.set(Array(now), forKey: "widgetFolded") }
        // Dark enough that the list reads the same whatever is behind the window; the glass shows as a faint tint.
        .background {
            // Glass in both looks. Each has a wash of its own tone over the glass, enough that words stay readable
            // whatever is behind the window and whether or not it is the focused one, and no more than that.
            // The Mac's long-standing blur, not macOS 26's Liquid Glass: Liquid Glass draws itself in over half a
            // second whenever its window appears or changes size, so the window opened bare and the glass then slid
            // in over it. This one is there from the first frame, and looks the same focused or not.
            if lightLook { ZStack { PanelBlur(light: true); Color.white.opacity(0.55) } }
            else { ZStack { PanelBlur(); Color.black.opacity(0.5) } }
        }
        .overlay(alignment: .bottom) { closedToast }
        .ignoresSafeArea()
    }

    func toggle(_ set: inout Set<String>, _ id: String) { if set.contains(id) { set.remove(id) } else { set.insert(id) } }
    func isActive(_ s: Session) -> Bool { !s.empty && (s.rank < 3 || s.seconds < 86_400) }

    static let closedGroup = "Recently closed · click to resume"
    struct SessionGroup: Identifiable { let id: String; let items: [Session]; let unused: [Session] }
    /// The list's contents: search, then the chosen filter, then grouped by repo or by state.
    func sessionGroups() -> [SessionGroup] {
        var rows = model.hits
        if filter == "active" { rows = rows.filter(isActive) }
        if groupBy == "state" {
            let buckets: [(String, (Session) -> Bool)] = [
                ("Needs you", { $0.rank == 0 }), ("Finished", { $0.rank == 1 }), ("Working", { $0.rank == 2 }),
                ("Idle, used today", { $0.rank == 3 && $0.seconds < 86_400 }), ("Idle, older", { $0.rank == 3 && $0.seconds >= 86_400 }),
            ]
            var out = buckets.map { SessionGroup(id: $0.0, items: rows.filter($0.1), unused: []) }.filter { !$0.items.isEmpty }
            let unused = rows.filter { $0.empty }
            if !unused.isEmpty { out.append(SessionGroup(id: "Never used", items: [], unused: unused)) }
            if filter == "all", !model.recentHits.isEmpty { out.append(SessionGroup(id: Self.closedGroup, items: model.recentHits, unused: [])) }
            return out
        }
        var out = repos(in: rows).map { name in
            SessionGroup(id: name, items: rows.filter { $0.project == name && !$0.empty }, unused: rows.filter { $0.project == name && $0.empty })
        }
        if filter == "all", !model.recentHits.isEmpty { out.append(SessionGroup(id: Self.closedGroup, items: model.recentHits, unused: [])) }
        return out
    }

    var searchRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(ink.opacity(0.45))
            TextField("", text: $model.query, prompt: Text("Search sessions").foregroundStyle(ink.opacity(0.35)))
                .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(ink).tint(ink)
            if detached { lookSwitch }
            gear
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    /// Which sessions to show, and how to group them. Both choices are remembered.
    func toolbar(roomy: Bool) -> some View {
        HStack(spacing: 6) {
            chip("All", model.hits.count, on: filter == "all") { filter = "all" }
            chip("Active", model.hits.filter(isActive).count, on: filter == "active") { filter = "active" }
            Spacer()
            // Named choices, not an icon: nobody guesses that a small grid icon means "there is another layout".
            // In a narrow window the two captions go, and the choices stay.
            if roomy { Text("View").font(.system(size: 11)).foregroundStyle(ink.opacity(0.35)) }
            chip("List", nil, on: layout != "cards") { layout = "list" }
            chip("Cards", nil, on: layout == "cards") { layout = "cards" }
            if roomy { Text("Group by").font(.system(size: 11)).foregroundStyle(ink.opacity(0.35)).padding(.leading, 8) } else { Spacer().frame(width: 4) }
            chip("Repo", nil, on: groupBy == "repo") { groupBy = "repo" }
            chip("State", nil, on: groupBy == "state") { groupBy = "state" }
        }
        .padding(.horizontal, 14).padding(.bottom, 9)
    }
    func chip(_ label: String, _ count: Int?, on: Bool, _ act: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(ink.opacity(on ? 0.95 : 0.55))
            if let count { Text("\(count)").foregroundStyle(ink.opacity(on ? 0.5 : 0.28)).monospacedDigit() }
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(ink.opacity(on ? 0.12 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: act)
    }

    /// A slim bar naming the group, how many are in it and what they are doing. Click to fold it.
    func groupHeader(_ g: SessionGroup) -> some View {
        let all = g.items, doing = [all.filter { $0.rank == 0 }.count, all.filter { $0.rank == 1 }.count, all.filter { $0.rank == 2 }.count]
        let note = groupBy == "state" ? "" : zip(doing, ["needs you", "finished", "working"]).filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        return HStack(spacing: 8) {
            Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(ink.opacity(0.4))
                .rotationEffect(.degrees(collapsed.contains(g.id) ? 0 : 90))
            if groupBy == "repo" && g.id != Self.closedGroup { RepoIcon().stroke(ink.opacity(0.6), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)).frame(width: 11, height: 11) }
            Text(g.id).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.opacity(0.82))
            Text("\(all.count)").font(.system(size: 11.5)).foregroundStyle(ink.opacity(0.32)).monospacedDigit()
            if !note.isEmpty { Text(note).font(.system(size: 11)).foregroundStyle(ink.opacity(0.5)) }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        // A faint wash of the ink, fainter than a highlighted row, so the two never read as the same thing.
        .background(ink.opacity(0.04))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { toggle(&collapsed, g.id) } }
    }

    @ViewBuilder func orb(_ s: Session) -> some View {
        if s.rank == 2 { Orb(tint: PortalMark.working, light: lightLook) }
        else if s.rank == 0 { Orb(spinning: false, light: lightLook) }
        else if s.rank == 1 { Orb(spinning: false, tint: PortalMark.done, glow: 0.6, light: lightLook) }
        else { Color.clear }   // idle, closed or never used: no orb. The space is kept so titles stay lined up.
    }
    func stateWord(_ s: Session) -> String { s.status == "closed" ? "closed" : ["needs you", "finished", "working", "idle", "unused"][s.rank] }
    func stateColor(_ s: Session) -> Color { s.rank == 0 ? lav : s.rank == 1 ? grn : s.rank == 2 ? ink.opacity(0.9) : ink.opacity(0.34) }

    /// A repo name with the small repository mark in front.
    func repoText(_ name: String, tone: Double = 0.45) -> Text {
        name.isEmpty ? Text("") : Text(Image(nsImage: RepoGlyph.image(tone, light: lightLook))).baselineOffset(-1.5) + Text(" " + name)
    }
    /// A branch name with the small git-branch mark in front, so it reads as a branch and not as a folder.
    func branchText(_ b: String?, lead: String = "", tone: Double = 0.45) -> Text {
        guard let b else { return Text("") }
        return Text(lead) + Text(Image(nsImage: BranchIcon.image(tone, light: lightLook))).baselineOffset(-1.5) + Text(" " + b)
    }

    /// One session on one line, its facts in columns that line up down the whole list.
    func sessionRow(_ s: Session, table: Bool) -> some View {
        let old = s.rank >= 3 && s.seconds >= 86_400   // idle since yesterday or earlier: shown quieter
        let repo = groupBy == "state" || s.status == "closed" ? s.project : ""
        return Hovering(id: s.id, onLeave: { if confirmClose == s.id { confirmClose = nil } }) { hovering in
        HStack(spacing: 12) {
            orb(s).frame(width: 12, height: 12).padding(.trailing, -3)
            if table {
                Text(s.title).font(.system(size: 13, weight: .medium)).foregroundStyle(ink.opacity(old ? 0.62 : 0.96))
                    .lineLimit(1).frame(width: 270, alignment: .leading)
                // The last thing you typed there; the recap if nothing has been typed.
                Text((showLast ? s.lastMessage : nil) ?? s.recap ?? "").font(.system(size: 12)).foregroundStyle(ink.opacity(old ? 0.28 : 0.5))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                // The repo and the branch are two pieces that shorten separately. As one line cut in the middle, a
                // long pair lost the branch icon and ran together ("storefront…saved-card-checkout"). The repo keeps up to
                // 40% of the column and the branch has the rest; each ends in "…" when it does not fit.
                GeometryReader { col in
                    HStack(spacing: 10) {
                        if !repo.isEmpty {
                            repoText(repo, tone: old ? 0.26 : 0.42).lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: s.branch == nil ? col.size.width : col.size.width * 0.4, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                        }
                        branchText(s.branch, tone: old ? 0.26 : 0.42).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .frame(width: col.size.width, height: col.size.height, alignment: .leading)
                }
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(ink.opacity(old ? 0.26 : 0.42))
                .frame(width: repo.isEmpty ? 170 : 250, height: 16)
                Text(stateWord(s)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(stateColor(s)).frame(width: 70, alignment: .leading)
                Text(s.age).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(ink.opacity(0.38)).frame(width: 52, alignment: .trailing)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.system(size: 13, weight: .medium)).foregroundStyle(ink.opacity(old ? 0.62 : 0.96)).lineLimit(1)
                    (Text(stateWord(s)).foregroundColor(stateColor(s)) + (Text("  \(s.age)" + (repo.isEmpty ? "" : "  ·  ")) + repoText(repo, tone: 0.4) + branchText(s.branch, lead: "  ·  ", tone: 0.4)).foregroundColor(ink.opacity(0.4)))
                        .font(.system(size: 11)).lineLimit(1)
                    if showLast, let asked = s.lastMessage {
                        Text(asked).font(.system(size: 11.5)).foregroundStyle(ink.opacity(old ? 0.3 : 0.62)).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 12).padding(.trailing, 16).padding(.vertical, table ? 7.5 : 6.5)
        // The session whose terminal is in front is highlighted, the same way as in the notch panel.
        // The session whose terminal is in front is highlighted, the same way as in the notch panel.
        .background(ink.opacity(s.id == model.currentId ? 0.11 : picked(s) ? 0.09 : hovering ? 0.05 : 0))
        .overlay(alignment: .leading) { if picked(s) { Rectangle().fill(ink.opacity(0.5)).frame(width: 2) } }
        .contentShape(Rectangle())
        
        // The single click acts at once. Listening for a double click the usual way made every single click wait
        // to see whether a second was coming, which felt like lag; here both are heard, independently.
        .onTapGesture { pick(s) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { app?.go(s) })
        .contextMenu { rowMenu(s) }
        }
    }

    /// One session as a card: its state on top, its name, where it is, and the last thing said in it.
    func sessionCard(_ s: Session) -> some View {
        let old = s.rank >= 3 && s.seconds >= 86_400
        let repo = groupBy == "state" || s.status == "closed" ? s.project : ""
        let here = s.id == model.currentId
        return Hovering(id: s.id, onLeave: { if confirmClose == s.id { confirmClose = nil } }) { hovering in
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if s.rank < 3 && s.status != "closed" { orb(s).frame(width: 12, height: 12) }
                Text(stateWord(s)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(stateColor(s))
                Text(s.age).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(ink.opacity(0.38))
                Spacer(minLength: 0)
            }
            .frame(height: 16)
            Text(s.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(ink.opacity(old ? 0.62 : 0.96))
                .lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            // The repo and the branch shorten separately, each ending in "…". As one line cut in the middle the two
            // ran together and the branch lost its icon ("storefront…saved-card-checkout").
            HStack(spacing: 10) {
                if !repo.isEmpty { repoText(repo, tone: old ? 0.26 : 0.42).lineLimit(1).truncationMode(.tail).layoutPriority(1) }
                branchText(s.branch, tone: old ? 0.26 : 0.42).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(ink.opacity(old ? 0.26 : 0.42))
            .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
            Text((showLast ? s.lastMessage : nil) ?? s.recap ?? " ").font(.system(size: 12)).foregroundStyle(ink.opacity(old ? 0.3 : 0.55))
                .lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(ink.opacity(here ? 0.12 : picked(s) ? 0.1 : hovering ? 0.07 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ink.opacity(picked(s) ? 0.55 : here ? 0.22 : 0.08), lineWidth: picked(s) ? 1 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        
        // The single click acts at once. Listening for a double click the usual way made every single click wait
        // to see whether a second was coming, which felt like lag; here both are heard, independently.
        .onTapGesture { pick(s) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { app?.go(s) })
        .contextMenu { rowMenu(s) }
        }
    }

    /// A click picks a session: its details show in the pane on the right, and "Go to session" (or a double-click, or
    /// Return) takes you there. When the window is too narrow for the pane, a click goes straight there.
    func pick(_ s: Session) { if paneShown { detailId = s.id } else { app?.go(s) } }
    func picked(_ s: Session) -> Bool { paneShown && detailId == s.id }

    @ViewBuilder func rowMenu(_ s: Session) -> some View {
        Button("Rename…") { app?.rename(s) }
        if s.status == "closed" { Button("Copy Resume Command") { copyResume(s) } }
        Button("Show folder in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.cwd) }
        if s.status != "closed" { Divider(); Button("Close Session…") { app?.askToEnd(s) } }
    }
    func copyResume(_ s: Session) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.resumeCommand, forType: .string)
    }

    /// One click between light and dark, in the stay-on-screen window only. It shows what a click gives you: a sun
    /// while dark, a moon while light. "Match the system" stays a choice in settings.
    var lookSwitch: some View {
        Image(systemName: lightLook ? "moon" : "sun.max").font(.system(size: 13)).foregroundStyle(ink.opacity(0.45))
            .frame(width: 16)
            .contentShape(Rectangle().inset(by: -6))
            .onTapGesture { UserDefaults.standard.set(lightLook ? "dark" : "light", forKey: "windowLook"); app?.applyWindowLook() }
            .help(lightLook ? "Switch to dark" : "Switch to light")
    }
    var gear: some View {
        Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(ink.opacity(0.45))
            .contentShape(Rectangle().inset(by: -6))
            .onTapGesture { app?.showSettings() }.help("Settings")
            .contextMenu {
                Button("Settings…") { app?.showSettings() }
                Divider()
                Button("Quit codehatch") { NSApp.terminate(nil) }
            }
    }
    /// The command that reopens a session from any terminal, shown in full with a copy button beside it.
    /// Seeing the command itself says what it is; a button labelled "copy resume" did not.
    func resumeLine(_ s: Session) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RESUME FROM A TERMINAL").font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(ink.opacity(0.35))
            HStack(spacing: 8) {
                Text(s.resumeCommand).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(ink.opacity(0.8))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 4)
                Image(systemName: copied == s.id ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ink.opacity(copied == s.id ? 0.95 : 0.6)).frame(width: 16)
                    .contentShape(Rectangle().inset(by: -6)).help("Copy")
                    .onTapGesture {
                        copyResume(s); copied = s.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copied == s.id { copied = nil } }
                    }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(lightLook ? Color.black.opacity(0.06) : Color.black.opacity(0.35)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ink.opacity(0.08), lineWidth: 0.5)))
        }
        .padding(.top, 20)
    }
    /// The x on a row. A session that is working or waiting on you asks once more before it closes.
    /// Shown for a few seconds after a close.
    @ViewBuilder var closedToast: some View {
        if let c = model.closed {
            HStack(spacing: 10) {
                Text("Closed \"\(c.title)\"").foregroundStyle(Color.white.opacity(0.85)).lineLimit(1)
                // Undo, in effect: put the session back where it was, in a new terminal.
                Text("Resume").foregroundStyle(.white).fontWeight(.semibold).fixedSize().contentShape(Rectangle())
                    .onTapGesture { model.closed = nil; if let s = c.session { app?.go(s) } }
            }
            .font(.system(size: 11.5, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 8)
            .background(Capsule().fill(Color(white: 0.16)).overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)))
            .padding(.bottom, 12).padding(.horizontal, 12)
            .transition(.opacity)
        }
    }

    /// Everything about one session: the one you last pointed at, or failing that the one that most wants you.
    @ViewBuilder var detailPane: some View {
        if let s = (model.sessions + model.recent).first(where: { $0.id == detailId }) ?? model.spotlight ?? model.sessions.first(where: { !$0.empty }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        orb(s).frame(width: 14, height: 14)
                        Text(stateWord(s)).font(.system(size: 12, weight: .medium)).foregroundStyle(stateColor(s))
                        Text(s.age == "now" ? "now" : "for \(s.age)").font(.system(size: 12)).foregroundStyle(ink.opacity(0.4))
                        Spacer()
                    }
                    Text(s.title).font(.system(size: 19, weight: .semibold)).foregroundStyle(ink.opacity(0.97))
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                    (repoText(s.project) + branchText(s.branch, lead: "  ·  ")).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(ink.opacity(0.45)).padding(.top, 5)
                    if let recap = s.recap { detailBlock("Where it is", recap) }
                    if let asked = s.lastAsked { detailBlock("You last asked", asked) }
                    if s.replyIsNewer, let reply = s.lastReply { detailBlock("Last reply", reply) }
                    if s.recap == nil && s.lastAsked == nil { detailBlock("Where it is", s.empty ? "Nothing has been asked in this session yet." : "No recap saved for this session yet.") }
                    HStack(spacing: 8) {
                        action(s.status == "closed" ? "Resume" : "Go to session", primary: true) { app?.go(s) }
                            .keyboardShortcut(.defaultAction)
                        action("Rename") { app?.rename(s) }
                    }
                    .padding(.top, 22)
                    if s.status == "closed" { resumeLine(s) }
                }
                .padding(22)
            }
        }
    }
    func detailBlock(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(ink.opacity(0.35))
            Text(text).font(.system(size: 13)).lineSpacing(3).foregroundStyle(ink.opacity(0.82)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(.top, 20)
    }
    func action(_ label: String, primary: Bool = false, _ act: @escaping () -> Void) -> some View {
        Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(primary ? paper : ink.opacity(0.85))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(primary ? ink.opacity(0.92) : ink.opacity(0.1)))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
    }

    @ViewBuilder var panelBody: some View {
        // Closed, the shape is exactly the notch: its width and the menu bar's height. On a Mac with no notch it is a
        // strip of no height at the top centre of the screen.
        let closedW: CGFloat = model.notchWidth > 0 ? model.notchWidth : 160
        // The notch's own height, not the menu bar's: the menu bar can be a point taller, and that point showed as a sliver
        // of black under the notch at the end of closing, just before the panel left the screen, like a bounce.
        let closedH: CGFloat = model.notchWidth > 0 ? (model.notchHeight > 0 ? model.notchHeight : model.barHeight) : 0
        // How far the tab with the orb reaches left of the notch, plus the shape's top flare (the same 6 points as the
        // tab's), so the closed shape's left edge is the tab's. Nothing when the tab isn't showing or there's no notch.
        let reach: CGFloat = model.notchWidth > 0 && model.tabWidth > 0 ? max(0, model.tabWidth - model.beaconNotch) : 0
        VStack(spacing: 0) {
            pill.frame(height: model.barHeight)
            list.padding(.horizontal, 8)   // clear of the shape's sides, which sit a little in from the top corners
        }
        .frame(width: Self.openWidth, height: Self.openHeight, alignment: .top)
        .overlay(alignment: .bottom) { closedToast }
        .opacity(model.open ? 1 : 0)
        .modifier(Grow(progress: model.open ? 1 : 0, closed: CGSize(width: closedW + reach, height: closedH), open: CGSize(width: Self.openWidth, height: Self.openHeight)))
        // Dark glass: the Mac's blur of whatever is behind, darkened, and solid black at the very top so it joins the
        // notch. This is the long-standing blur, not macOS 26's Liquid Glass: that one draws itself in over half a
        // second every time its size changes, pale and without its edge, which a panel that grows cannot hide. This
        // one is complete from the first frame, so the panel is glass the whole way open, with nothing to cover up.
        .background(
            ZStack {
                PanelBlur()
                Color.black.opacity(0.22)   // how dark the glass is: lower lets more of what is behind show through
                // Solid black for the height of the menu bar, so the top of the panel is one piece with the notch, then
                // easing into the glass below.
                VStack(spacing: 0) {
                    Color.black.frame(height: model.barHeight + 4)
                    // One slow fade the whole way down, never a hard line: nearly black at the top, still dark through the
                    // middle, and only the bottom part of the panel is the clear glass.
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.92), location: 0.2), .init(color: .black.opacity(0.8), location: 0.45), .init(color: .black.opacity(0.55), location: 0.68), .init(color: .black.opacity(0.22), location: 0.87), .init(color: .black.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
                }
            }
        )
        // The notch's own outline, grown: the top corners curve outward into the top edge of the screen, the way the
        // notch itself meets it, and the bottom corners are rounded. No drawn edge; the shape is the edge.
        .clipShape(NotchShape(top: model.open ? 10 : 6, bottom: model.open ? 18 : 9))
        // Closed, the shape is the notch and the tab beside it as one piece, so it sits left of centre by half the tab.
        .modifier(Shift(progress: model.open ? 1 : 0, closed: -reach / 2))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var dots: some View {
        PortalMark(active: model.active.count)
    }
    var brand: some View {
        HStack(spacing: 8) {
            // No logo: a native tool does not need to sign its own panel. Just the session that most recently
            // asked for you, or failing that the one working now.
            if let s = model.spotlight {
                // The same orb as on the session's row: turning while it works, still when it needs you, green when done.
                orb(s).frame(width: 12, height: 12)
                // The orb says the state; the words are the session's name. The same as beside the closed notch.
                Text(s.title).foregroundStyle(ink.opacity(0.88)).lineLimit(1).truncationMode(.tail)
                .font(.system(size: 11.5, weight: .medium))
                .contentShape(Rectangle())
                
                .onTapGesture { app?.go(s) }
            }
        }
    }
    var stats: some View {
        Text(model.summary).font(.system(size: 11.5, weight: .medium)).foregroundStyle(ink.opacity(0.6)).lineLimit(1).fixedSize()
    }
    /// The counts for a space of limited width: the fullest version that fits, so they never run under the camera.
    var fittedStats: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(model.summaries, id: \.self) { line in
                Text(line).font(.system(size: 11.5, weight: .medium)).foregroundStyle(ink.opacity(0.6)).lineLimit(1).fixedSize()
            }
        }
    }
    @ViewBuilder var pill: some View {
        if model.notchWidth > 0 {
            // Either side of the camera: the stats on its left, the portal on its right.
            let side = (Self.openWidth - model.notchWidth) / 2
            HStack(spacing: 0) {
                brand.padding(.leading, 18).frame(width: side, alignment: .leading)
                Color.clear.frame(width: model.notchWidth)
                fittedStats.padding(.leading, 10).padding(.trailing, 18).frame(width: side, alignment: .trailing)
            }
        } else {
            HStack { brand; Spacer(); stats }.padding(.horizontal, 18)
        }
    }

    var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(ink.opacity(0.45))
                TextField("", text: $model.query, prompt: Text("Search sessions").foregroundStyle(ink.opacity(0.35)))
                    .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(ink).tint(ink)
                    .focused($searchFocused)
                if !detached {
                    Image(systemName: "macwindow.on.rectangle").font(.system(size: 13)).foregroundStyle(ink.opacity(0.45))
                        .contentShape(Rectangle().inset(by: -6))   // a hand, like every other button here
                        .onTapGesture { app?.toggleWidget() }
                        .help("Keep a copy on screen that you can move to another display")
                }
                gear
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
            .onChange(of: model.open) { _, isOpen in searchFocused = isOpen }
            .onChange(of: model.query) { _, _ in model.selected = 0 }
            // One click to see a single repo. Only shown when there is more than one to choose between.
            if !detached && (model.repoNames.count > 1 || !model.recent.isEmpty) {
                // With many repos the chips wrap onto a second line, and a third, so every one stays in view.
                    Wrap(spacing: 6) {
                        chip("All", model.sessions.count, on: model.repoFilter == nil) { model.repoFilter = nil; model.selected = hereIndex }
                        ForEach(model.repoNames, id: \.self) { name in
                            chip(name, model.sessions.filter { $0.project == name }.count, on: model.repoFilter == name) {
                                model.repoFilter = model.repoFilter == name ? nil : name; model.selected = hereIndex
                            }
                        }
                        if !model.recent.isEmpty {
                            chip("Recently closed", model.recent.count, on: model.repoFilter == Model.closedOnly) {
                                model.repoFilter = model.repoFilter == Model.closedOnly ? nil : Model.closedOnly; model.selected = hereIndex
                            }
                        }
                    }.padding(.horizontal, 14).padding(.bottom, 9)
            }
            Rectangle().fill(ink.opacity(0.08)).frame(height: 1)
            GeometryReader { geo in
                let rows = model.filtered
                ScrollViewReader { _ in
                ScrollView {
                    Group {
                        // Narrow: one column, repos one under another.
                        VStack(spacing: 2) {
                            // By recency each row names its own repo; by repo there is a heading per repo.
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, s in
                                if byRepo && (i == 0 || rows[i - 1].project != s.project) {
                                    repoHeader(s.project, count: rows.filter { $0.project == s.project }.count).padding(.top, i == 0 ? 4 : 14)
                                }
                                row(s, selected: i == model.selected && !detached, showRepo: !byRepo)
                            }
                            // Sessions that are no longer open. Clicking one reopens it in a new terminal.
                            let past = model.recentHits
                            if !past.isEmpty {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 10, weight: .medium)).foregroundStyle(ink.opacity(0.45))
                                    Text("Recently closed").font(.system(size: 11, weight: .semibold)).foregroundStyle(ink.opacity(0.5))
                                    Text("click to resume").font(.system(size: 11)).foregroundStyle(ink.opacity(0.25))
                                    Spacer()
                                }.padding(.horizontal, 12).padding(.top, rows.isEmpty ? 4 : 14).padding(.bottom, 2)
                                // One fold per repo, shut to begin with: a long tail of old sessions stays out of the way
                                // until you want one. Searching opens the repos that have matches.
                                ForEach(repos(in: past), id: \.self) { name in
                                    closedRepoHeader(name, count: past.filter { $0.project == name }.count, open: closedFoldOpen(name)).padding(.horizontal, 4)
                                    if closedFoldOpen(name) {
                                        ForEach(past.filter { $0.project == name }) { s in row(s, selected: false, showRepo: false) }
                                    }
                                }
                            }
                        }.padding(8)
                    }
                }
                }
            }
        }
        .frame(height: detached ? nil : Self.openHeight - model.barHeight)
    }

    func repos(in rows: [Session]) -> [String] { var out: [String] = []; for s in rows where !out.contains(s.project) { out.append(s.project) }; return out }

    /// A repo's fold inside "Recently closed": click to show or hide its sessions.
    func closedRepoHeader(_ name: String, count: Int, open: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(ink.opacity(0.4)).rotationEffect(.degrees(open ? 90 : 0))
            RepoIcon().stroke(ink.opacity(0.5), style: StrokeStyle(lineWidth: 1.05, lineCap: .round, lineJoin: .round)).frame(width: 10.5, height: 10.5)
            Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(ink.opacity(0.7))
            Text("\(count)").font(.system(size: 11)).foregroundStyle(ink.opacity(0.3)).monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { if model.query.isEmpty { toggle(&openClosed, name) } else { toggle(&shutInSearch, name) } } }
    }
    func repoHeader(_ name: String, count: Int) -> some View {
        HStack {
            RepoIcon().stroke(ink.opacity(0.45), style: StrokeStyle(lineWidth: 1.05, lineCap: .round, lineJoin: .round)).frame(width: 10.5, height: 10.5)
            Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(ink.opacity(0.5))
            Text("\(count)").font(.system(size: 11)).foregroundStyle(ink.opacity(0.25))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.bottom, 3)
    }

    func row(_ s: Session, selected: Bool, showRepo: Bool = false) -> some View {
        Hovering(id: s.id, onLeave: { if confirmClose == s.id { confirmClose = nil } }) { hovering in
        HStack(alignment: .top, spacing: 8) {
            Group {
                if s.rank == 2 { Orb(tint: PortalMark.working, light: lightLook) }
                else if s.rank == 0 { Orb(spinning: false, light: lightLook) }
                else if s.rank == 1 { Orb(spinning: false, tint: PortalMark.done, glow: 0.6, light: lightLook) }
                else { Color.clear }   // idle, closed or never used: no orb. The space is kept so titles stay lined up.
            }.frame(width: 12, height: 12).padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(s.title).font(.system(size: 13, weight: .medium)).foregroundStyle(ink.opacity(0.95)).lineLimit(1)
                }
                (repoText(showRepo ? s.project : "", tone: 0.75) + branchText(s.branch, lead: showRepo ? "  ·  " : "", tone: 0.75))
                    .font(.system(size: 11.5)).foregroundStyle(ink.opacity(0.75)).lineLimit(1)
                // In the notch panel: the last thing you typed there, on one line, cut short if it is long.
                if !detached, showLast, let asked = s.lastMessage {
                    Text(asked).font(.system(size: 11.5)).foregroundStyle(ink.opacity(0.62)).lineLimit(1).truncationMode(.tail)
                }
                // Where the session is. Shown in the stay-on-screen window, where there is room for it.
                if detached, let recap = s.gist {
                    Text(recap).font(.system(size: 11.5)).foregroundStyle(ink.opacity(0.66)).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
            }
            Spacer()
            // The time, at the far right in fixed-width digits: it can count up without moving anything else.
            // The state and how long it has been in it, together at the far right: the repo and branch below are
            // then one uninterrupted line. Fixed-width digits, so the time can count without moving anything.
            (Text(s.statusText).foregroundColor(s.rank == 1 ? PortalMark.done : s.rank == 0 ? PortalMark.amber : ink.opacity(s.rank == 2 ? 0.7 : 0.4))
             + Text("  " + s.age).foregroundColor(ink.opacity(0.4)))
                .font(.system(size: 11)).monospacedDigit().fixedSize().padding(.top, 2.5)
        }
        .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(ink.opacity(selected ? 0.11 : hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        
        .onTapGesture { dbg("row clicked: \(s.title)"); app?.go(s) }
        .contextMenu {
            Button("Rename…") { app?.rename(s) }
            if s.status == "closed" { Button("Copy Resume Command") { copyResume(s) } }
            Button("Show folder in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.cwd) }
            if s.status != "closed" { Divider(); Button("Close Session…") { app?.askToEnd(s) } }
        }
        }
    }
}

/// The panel under the menu bar icon: the same five choices a menu would have, drawn by codehatch.
struct MenuPanel: View {
    weak var app: AppDelegate?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            item("sessions", "Show sessions")
            item("window", "Open the window")
            Divider().padding(.horizontal, 12).padding(.vertical, 5)
            item("settings", "Settings…", key: "⌘,")
            item("updates", "Check for updates…")
            Divider().padding(.horizontal, 12).padding(.vertical, 5)
            item("quit", "Quit codehatch", key: "⌘Q")
        }
        .padding(6)
        .frame(width: 240, height: 182, alignment: .top)
        // Darker than a plain blur, to match the system's own menu bar panels (Wi-Fi, Battery) beside it.
        .background(ZStack { PanelBlur(light: scheme == .light); (scheme == .light ? Color.white.opacity(0.35) : Color.black.opacity(0.38)) })
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
    func item(_ id: String, _ title: String, key: String = "") -> some View {
        Hovering(id: id) { over in
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if !key.isEmpty { Text(key).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(over ? 0.1 : 0)))
            .contentShape(Rectangle())
            .onTapGesture { app?.menuChose(id) }
        }
    }
}
