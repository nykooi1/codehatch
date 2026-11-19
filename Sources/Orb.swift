import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

/// One orb for every state, so they belong together: a swirl of light around a bright core.
/// Working turns and breathes. Needs-you is the same orb held still. Idle is a small dim grey one.
struct Orb: View {
    var spinning = true
    var tint: Color = PortalMark.amber
    var size: CGFloat = 11
    var glow: Double = 1
    /// On a light background. The usual orb is light itself (white in the swirl, a white core, a glow), which is
    /// nearly invisible on white. There it is drawn as a small saturated gem instead: deep colour, a bright spot.
    var light = false
    /// The middle of the orb on a light background: a paler shade of its own colour, soft-edged. A white dot there
    /// looked like a hole punched in it.
    static func heart(_ tint: NSColor) -> NSColor {
        let base = tint == NSColor(PortalMark.amber) ? NSColor(red: 1.0, green: 0.72, blue: 0.30, alpha: 1) : tint == NSColor(PortalMark.working) ? NSColor(red: 0.30, green: 0.62, blue: 1.0, alpha: 1) : tint
        return (base.blended(withFraction: 0.45, of: .white) ?? base).withAlphaComponent(0.9)
    }
    /// The swirl's colours, going round.
    static func swirl(_ tint: NSColor, light: Bool) -> [NSColor] {
        let amber = tint == NSColor(PortalMark.amber)
        if light {
            // Darkening the working blue turned it a dull slate. It gets a vivid blue and a deep royal one instead.
            let blue = tint == NSColor(PortalMark.working)
            let base = amber ? NSColor(red: 0.98, green: 0.55, blue: 0.05, alpha: 1) : blue ? NSColor(red: 0.13, green: 0.50, blue: 1.0, alpha: 1) : (tint.blended(withFraction: 0.22, of: .black) ?? tint)
            let deep = amber ? NSColor(red: 0.90, green: 0.30, blue: 0.02, alpha: 1) : blue ? NSColor(red: 0.02, green: 0.28, blue: 0.86, alpha: 1) : (tint.blended(withFraction: 0.5, of: .black) ?? tint)
            let pale = base.blended(withFraction: 0.2, of: .white) ?? base   // only a little lighter: a pale patch on white reads as a bite out of the orb
            return [pale, base, deep, base, pale]
        }
        // The deep stretch is let through only in part, like the blue and green orbs' thin stretch: a soft dark spot, not a solid ball.
        if amber { return [.white, NSColor(red: 1.0, green: 0.80, blue: 0.36, alpha: 1), NSColor(PortalMark.ember).withAlphaComponent(0.42), tint, .white] }
        return [.white, tint, NSColor.white.withAlphaComponent(0.08), tint.withAlphaComponent(0.6), .white]
    }
    var body: some View {
        if spinning {
            // Moving orbs are drawn and animated by the system's compositor. A SwiftUI animation that repeats
            // forever makes the whole window lay itself out again on every frame, which showed up as a
            // steady 10% of a processor core while anything was working.
            SpinningOrb(tint: NSColor(tint), light: light).frame(width: size, height: size)
        } else {
            ZStack {
                // Blue and green darken handsomely where the swirl thins out. Amber does not: darkened, it is brown, and
                // the orb looks like dull metal. So the amber orb's thin stretch is a deeper, hotter orange instead.
                Circle().fill(AngularGradient(colors: Self.swirl(NSColor(tint), light: light).map { Color(nsColor: $0) }, center: .center))
                    .rotationEffect(.degrees(35))
                Circle().fill(RadialGradient(colors: [light ? Color(nsColor: Self.heart(NSColor(tint))) : .white, (light ? Color(nsColor: Self.heart(NSColor(tint))) : .white).opacity(0)], center: .center, startRadius: 0, endRadius: size * (light ? 0.34 : 0.3)))
            }
            .frame(width: size, height: size)
            .shadow(color: (tint == PortalMark.amber ? PortalMark.ember : tint).opacity(light ? 0 : glow * (tint == PortalMark.amber ? 0.9 : 0.75)), radius: light || glow <= 0 ? 0 : 5)
        }
    }
}

struct PulsingGlow: NSViewRepresentable {
    func makeNSView(context: Context) -> GlowLayerView { GlowLayerView() }
    func updateNSView(_ v: GlowLayerView, context: Context) {}
}

/// A soft amber glow that fades in and out, animated by the compositor.
final class GlowLayerView: NSView {
    private let dot = CALayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = false
        let c = NSColor(PortalMark.amber)
        dot.backgroundColor = c.withAlphaComponent(0.25).cgColor
        dot.shadowColor = c.cgColor; dot.shadowOffset = .zero; dot.shadowRadius = 7; dot.shadowOpacity = 1
        layer?.addSublayer(dot)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.frame = bounds.insetBy(dx: 3, dy: 2); dot.cornerRadius = 4
        CATransaction.commit()
        animate()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); animate() }
    private func animate() {
        guard window != nil, dot.animation(forKey: "pulse") == nil else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.25; a.toValue = 1; a.duration = 1.4; a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); a.isRemovedOnCompletion = false
        dot.add(a, forKey: "pulse")
    }
}

struct SpinningOrb: NSViewRepresentable {
    let tint: NSColor
    var light = false
    func makeNSView(context: Context) -> OrbLayerView { let v = OrbLayerView(); v.light = light; v.tint = tint; return v }
    func updateNSView(_ v: OrbLayerView, context: Context) { if v.light != light { v.light = light }; if v.tint != tint { v.tint = tint } }
}

/// The working orb as layers: a swirl that turns, a bright core, and a glow that breathes.
final class OrbLayerView: NSView {
    private let body = CALayer(), ring = CAGradientLayer(), core = CAGradientLayer()
    var tint = NSColor.white { didSet { paint() } }
    var light = false { didSet { paint() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        ring.type = .conic; ring.startPoint = CGPoint(x: 0.5, y: 0.5); ring.endPoint = CGPoint(x: 0.5, y: 0); ring.masksToBounds = true
        core.type = .radial; core.startPoint = CGPoint(x: 0.5, y: 0.5); core.endPoint = CGPoint(x: 0.8, y: 0.8)
        core.colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        body.shadowOffset = .zero; body.shadowRadius = 5
        body.addSublayer(ring); body.addSublayer(core)
        layer?.addSublayer(body)
        paint()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func paint() {
        ring.colors = Orb.swirl(tint, light: light).map(\.cgColor)
        let heart = light ? Orb.heart(tint) : NSColor.white
        core.colors = [heart.cgColor, heart.withAlphaComponent(0).cgColor]
        body.shadowColor = light ? NSColor.clear.cgColor : tint.cgColor; body.shadowRadius = 5   // no glow on a light background
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        body.frame = bounds; ring.frame = bounds; core.frame = bounds
        ring.cornerRadius = bounds.width / 2
        CATransaction.commit()
        animate()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); animate() }
    /// Layer animations are dropped when a view leaves its window, so they are put back whenever it has one.
    private func animate() {
        guard window != nil, ring.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0; spin.toValue = -2 * Double.pi; spin.duration = 1.5; spin.repeatCount = .infinity; spin.isRemovedOnCompletion = false
        ring.add(spin, forKey: "spin")
        func breathe(_ key: String, _ from: Double, _ to: Double) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from; a.toValue = to; a.duration = 1.1; a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); a.isRemovedOnCompletion = false
            body.add(a, forKey: key)
        }
        breathe("transform.scale", 0.92, 1.08)
        breathe("shadowOpacity", 0.45, 0.95)
    }
}
/// A pointing-hand cursor over things you can click.

struct PortalMark: View {
    let active: Int
    /// "Needs you": a warm amber, the colour of waiting, clearly apart from the blue of working.
    static let amber = Color(red: 1.0, green: 0.67, blue: 0.24)
    /// The deep end of the amber orb's swirl.
    static let ember = Color(red: 1.0, green: 0.40, blue: 0.08)
    /// Working: the blue macOS uses for anything in progress.
    static let working = Color(red: 0.25, green: 0.59, blue: 1.0)
    /// Finished: a soft green, the usual colour for done.
    static let done = Color(red: 0.35, green: 0.87, blue: 0.55)
    // Loaded from inside the app itself, never from the project folder.
    static let image: NSImage? = Bundle.main.url(forResource: "portal", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        Group {
            if let img = Self.image {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
            } else {
                Arch().stroke(Self.amber, style: StrokeStyle(lineWidth: 1.8, lineCap: .round)).frame(width: 10, height: 13)
            }
        }
        // The mark is a plain white line drawing: no glow or shadow, which would only soften it.
    }
}
