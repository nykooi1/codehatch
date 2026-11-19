import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

/// The tab placed in the notch's window: its right end is the notch's right edge, so it reaches out to the left.
struct NotchTab: View {
    @ObservedObject var model: Model
    var body: some View {
        let reach = 200 + TabShape.flare
        Beacon(model: model)
            .frame(width: reach + model.beaconNotch, height: model.notchHeight > 0 ? model.notchHeight : model.barHeight)
            .offset(x: -reach / 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// What the beacon beside the notch shows: the orb and a word, on a black tab that reads as part of the notch.
/// The word is needed: a bare green dot beside the camera is what macOS shows when the camera is recording.
struct Beacon: View {
    @ObservedObject var model: Model
    var clicked: () -> Void = {}
    @AppStorage("showBeacon") private var wanted = true
    @AppStorage("beaconShows") private var shows = "orb"
    /// What goes beside the orb: the words, and the number that follows them, for a way of showing ("name", "state" or
    /// "orb"). Nil when nothing is going on and nothing shows.
    static func label(sessions: [Session], spotlight: Session?, shows: String) -> (text: String, count: String)? {
        guard let s = spotlight else { return nil }
        let more = sessions.filter { $0.rank == s.rank }.count - 1
        let text = shows == "state" ? ["needs you", "finished", "working"][min(s.rank, 2)] : shows == "orb" ? "" : short(s.title)
        return (text, more > 0 ? (shows == "orb" ? "\(more + 1)" : "+\(more)") : "")
    }
    /// The first few words of a name: at most 16 characters, cut at a word where it can be.
    static func short(_ title: String) -> String {
        let limit = 16
        guard title.count > limit else { return title }
        var cut = String(title.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= 8 { cut = String(cut[..<space]) }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
    var body: some View {
        ZStack(alignment: .trailing) {
            // It stays put while the panel is open: the panel opens over it (its black top covers the tab), and is
            // simply there again as the panel closes. Tucking it away and growing it back each time was busywork.
            if wanted, let s = model.spotlight {
                let more = model.sessions.filter { $0.rank == s.rank }.count - 1   // others in the same state
                HStack(spacing: 6) {
                    Group {
                        if s.rank == 2 { Orb(tint: PortalMark.working) }
                        else if s.rank == 0 { Orb(spinning: false) }
                        else { Orb(spinning: false, tint: PortalMark.done, glow: 0.6) }
                    }
                    .frame(width: 12, height: 12)
                    // The orb's colour already says the state, so the words say which session it is: the start of its
                    // name. Kept short, because this sits over the menu bar. The state word, or nothing, is a setting.
                    let l = Self.label(sessions: model.sessions, spotlight: s, shows: shows) ?? ("", "")
                    if !l.text.isEmpty {
                        Text(l.text).font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(shows == "state" ? (s.rank == 0 ? PortalMark.amber : s.rank == 1 ? PortalMark.done : Color.white.opacity(0.75)) : Color.white.opacity(0.82))
                            .fixedSize()
                    }
                    // Only one session fits here, so say when others are in the same state: "+2", or the total with the orb alone.
                    if !l.count.isEmpty {
                        Text(l.count).font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.5)).fixedSize().padding(.leading, -1)
                    }
                }
                // The black runs right across the notch to its far edge, the way notch apps usually draw their closed state: one
                // black shape of our own, exactly the notch's height, lying over the real notch. So the bottom edge you
                // see is a single drawn line from the tab's left end to the notch's right end, with nothing to line up,
                // and the notch's own rounded corner is the one that shows at the right. On a Mac with no notch it is a
                // small black tab hanging from the top of the screen, rounded on both sides.
                .padding(.leading, 12 + TabShape.flare).padding(.trailing, 9 + (model.beaconNotch > 0 ? model.beaconNotch : 4))
                .frame(maxHeight: .infinity)
                .background(TabShape(far: model.beaconNotch > 0 ? 12 : 10).fill(.black))
                .background(GeometryReader { g in Color.clear
                    .onAppear { withAnimation(Self.spring) { model.tabWidth = g.size.width } }
                    .onChange(of: g.size.width) { _, w in withAnimation(Self.spring) { model.tabWidth = w } }
                    .onDisappear { model.tabWidth = 0 } })
                .contentShape(Rectangle())
                
                .onTapGesture(perform: clicked)
                .help((s.rank == 1 ? "Click to clear" : "Click to see your sessions") + (more > 0 ? " · \(more) more \(["need you", "finished", "working"][min(s.rank, 2)])" : ""))
                // It grows out of the notch sideways and goes back into it, instead of fading in and out. The part
                // over the notch is black on black, so at the start it is simply the notch, which then widens.
                .transition(.modifier(active: OutOfNotch(shown: 0, notch: model.beaconNotch), identity: OutOfNotch(shown: 1, notch: model.beaconNotch)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        // Not shown at all while the panel is open: the panel already says the same thing, and macOS can briefly draw
        // either window in front of the other (swiping between desktops, for one). It is simply back as the panel closes,
        // with no fade or slide.
        .opacity(model.open ? 0 : 1)
        // Back only as the panel finishes shrinking into it, not over the panel's title while it is still closing.
        .animation(model.open ? nil : .easeOut(duration: 0.12).delay(0.22), value: model.open)
        .transaction(value: model.open) { $0.animation = nil }
        .animation(Self.spring, value: model.spotlight?.rank)
        .animation(Self.spring, value: model.spotlight?.id)
        // As the tab starts sliding back into the notch, the black behind it (the panel's closed shape) shrinks with it,
        // in step. Left until the tab had gone, that black stayed out on its own and then vanished at once.
        .onChange(of: wanted && model.spotlight != nil) { _, showing in
            if !showing { withAnimation(Self.spring) { model.tabWidth = 0 } }
        }
    }
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.92)
}

/// The codehatch portal arch. Dim when nothing is happening; glows and shows a count when sessions are active.
/// The surface behind the panel and the window: Liquid Glass on macOS 26 and later, darkened so white text
/// stays readable over anything; the older frosted blur everywhere else.
/// The blur behind the notch panel: the Mac's own dark translucent material. Told to stay "active", so it looks the
/// same whether or not the panel is the focused window.
/// The status tab's outline: like the notch's own, its outer top corner curves outward into the top edge of the screen,
/// and its outer bottom corner is rounded. The far end (lying over the notch) is square at the top and rounded at the
/// bottom, matching the notch's corner.
struct TabShape: Shape {
    static let flare: CGFloat = 6
    var near: CGFloat = 10
    var far: CGFloat
    func path(in r: CGRect) -> Path {
        let f = Self.flare
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + f, y: r.minY + f), control: CGPoint(x: r.minX + f, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + f, y: r.maxY - near))
        p.addQuadCurve(to: CGPoint(x: r.minX + f + near, y: r.maxY), control: CGPoint(x: r.minX + f, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - far, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - far), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// The status tab coming out of the notch: everything left of the notch is uncovered from the notch outward, and the
/// orb and name fade in as they are uncovered. At 0 only the part over the notch is left, which cannot be seen.
struct OutOfNotch: ViewModifier, Animatable {
    var shown: CGFloat
    let notch: CGFloat
    var animatableData: CGFloat { get { shown } set { shown = newValue } }
    func body(content: Content) -> some View {
        content
            .mask(alignment: .trailing) {
                GeometryReader { g in
                    // The tab's own outline, not a straight cut: its rounded corner and top flare travel with the edge,
                    // so going back in it looks like the notch itself shrinking, with no square corner on the way.
                    TabShape(far: 0).frame(width: notch + max(0, g.size.width - notch) * max(0, shown)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }
            .opacity(notch > 0 ? 1 : Double(min(1, shown * 1.5)))   // without a notch to come out of, it also fades
    }
}
