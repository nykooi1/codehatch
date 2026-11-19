import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

/// The panel's size as it opens and closes, between exactly the notch and exactly full size, and never outside those.
/// A spring creeps over its last few points, and may go a little past its mark. Both are absorbed here: the size reaches
/// the notch's exact size a touch before the spring has finished, and holds there. So closing ends the moment the shape
/// is the notch, with no sliver lingering around it and no moment where the shape is narrower than the notch.
struct Grow: ViewModifier, Animatable {
    var progress: CGFloat
    var closed: CGSize
    let open: CGSize
    // The closed width moves too: it follows the tab beside the notch as it grows out and slides back in.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, closed.width) }
        set { progress = newValue.first; closed.width = newValue.second }
    }
    func body(content: Content) -> some View {
        let q = max(0, min(1, (progress - 0.035) / 0.95))
        content.frame(width: closed.width + (open.width - closed.width) * q, height: closed.height + (open.height - closed.height) * q, alignment: .top)
    }
}

/// Moves the panel sideways in step with Grow: by `closed` when closed, not at all when open.
struct Shift: ViewModifier, Animatable {
    var progress: CGFloat
    var closed: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, closed) }
        set { progress = newValue.first; closed = newValue.second }
    }
    func body(content: Content) -> some View {
        let q = max(0, min(1, (progress - 0.035) / 0.95))
        content.offset(x: closed * (1 - q))
    }
}

/// The shape of a panel hanging from the top of the screen. It is full width only along the very top; just below, each
/// side curves inward (the same outward flare the notch has where it meets the screen's edge), then runs straight down
/// to a rounded bottom corner.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        let t = min(top, r.width / 4, r.height / 2), b = min(bottom, r.width / 4, max(0, r.height - t))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct PanelBlur: NSViewRepresentable {
    var light = false
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow; v.state = .active
        paint(v)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { paint(v) }
    private func paint(_ v: NSVisualEffectView) {
        v.material = light ? .sidebar : .hudWindow
        v.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    }
}

struct GlassBack<S: Shape>: View {
    let shape: S
    let dim: Double
    let frosted: Color
    /// Extra black laid over the glass. The system turns glass pale when its window is not the focused one,
    /// and the stay-on-screen window almost never is, so its darkness cannot be left to the glass alone.
    var shade: Double = 0
    /// What the glass is tinted and overlaid with: black for the dark look, white for the light one.
    var tone: Color = .black
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            ZStack { Color.clear.glassEffect(.regular.tint(tone.opacity(dim)), in: shape); shape.fill(tone.opacity(shade)) }
        } else {
            old
        }
        #else
        old
        #endif
    }
    var old: some View { ZStack { shape.fill(.ultraThinMaterial); shape.fill(frosted) } }
}

/// The usual git-branch mark: a line between two dots, with a third dot branching off to the right.
/// Drawn here because the system symbol set has no match for it.
enum BranchIcon {
    /// Text does not tint an image placed inside it, so the mark is drawn in the text's own shade of white.
    static var made: [Double: NSImage] = [:]
    static func image(_ tone: Double, light: Bool = false) -> NSImage {
        let key = light ? -tone : tone
        if let i = made[key] { return i }
        let size: CGFloat = 12, k = size / 16
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let t = NSAffineTransform(); t.scale(by: k); t.concat()
            (light ? NSColor.black : NSColor.white).withAlphaComponent(tone).setStroke()
            let p = NSBezierPath(); p.lineWidth = 1.9; p.lineCapStyle = .round
            for c in [NSPoint(x: 4.25, y: 3.25), NSPoint(x: 4.25, y: 12.75), NSPoint(x: 11.75, y: 3.25)] {
                p.appendOval(in: NSRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3))
            }
            p.move(to: NSPoint(x: 4.25, y: 4.75)); p.line(to: NSPoint(x: 4.25, y: 11.25))
            p.move(to: NSPoint(x: 11.75, y: 4.75)); p.line(to: NSPoint(x: 11.75, y: 6))
            p.curve(to: NSPoint(x: 10, y: 7.75), controlPoint1: NSPoint(x: 11.75, y: 7), controlPoint2: NSPoint(x: 11, y: 7.75))
            p.line(to: NSPoint(x: 6, y: 7.75))
            p.curve(to: NSPoint(x: 4.25, y: 9.5), controlPoint1: NSPoint(x: 5, y: 7.75), controlPoint2: NSPoint(x: 4.25, y: 8.5))
            p.stroke()
            return true
        }
        made[key] = img
        return img
    }
}

/// The repository mark as an image, for placing inside a line of text beside a repo name.
enum RepoGlyph {
    static var made: [Double: NSImage] = [:]
    static func image(_ tone: Double, light: Bool = false) -> NSImage {
        let key = light ? -tone : tone
        if let i = made[key] { return i }
        let size: CGFloat = 11.5, k = size / 16
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let t = NSAffineTransform(); t.scale(by: k); t.concat()
            (light ? NSColor.black : NSColor.white).withAlphaComponent(tone).setStroke()
            let p = NSBezierPath(roundedRect: NSRect(x: 2.75, y: 1.5, width: 10.5, height: 12.5), xRadius: 1.6, yRadius: 1.6)
            p.lineWidth = 1.6; p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.move(to: NSPoint(x: 2.75, y: 10.5)); p.line(to: NSPoint(x: 13.25, y: 10.5))
            p.move(to: NSPoint(x: 5.5, y: 12.3)); p.line(to: NSPoint(x: 5.5, y: 15.4)); p.line(to: NSPoint(x: 7, y: 14.4)); p.line(to: NSPoint(x: 8.5, y: 15.4)); p.line(to: NSPoint(x: 8.5, y: 12.3))
            p.stroke()
            return true
        }
        made[key] = img
        return img
    }
}

/// The usual repository mark: a closed book with a band across the foot and a bookmark hanging from it.
struct RepoIcon: Shape {
    func path(in r: CGRect) -> Path {
        let k = min(r.width, r.height) / 16
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * k) }
        var p = Path()
        p.addRoundedRect(in: CGRect(x: r.minX + 2.75 * k, y: r.minY + 1.5 * k, width: 10.5 * k, height: 12.5 * k), cornerSize: CGSize(width: 1.6 * k, height: 1.6 * k))
        p.move(to: pt(2.75, 10.5)); p.addLine(to: pt(13.25, 10.5))
        p.move(to: pt(5.5, 12.3)); p.addLine(to: pt(5.5, 15.6)); p.addLine(to: pt(7, 14.5)); p.addLine(to: pt(8.5, 15.6)); p.addLine(to: pt(8.5, 12.3))
        return p
    }
}

struct Arch: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); let rad = r.width / 2
        p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
        p.addArc(center: CGPoint(x: r.midX, y: r.minY + rad), radius: rad, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        return p
    }
}
