import AppKit
import SwiftUI
import Carbon.HIToolbox
import SQLite3
import Sparkle
import ServiceManagement

/// Which row or card the pointer is over, worked out by codehatch itself for the whole window: every row reports where
/// it is, and every pointer movement anywhere is checked against those places. SwiftUI's own per-view hover tracking
/// only delivers a change when the next event arrives in an app that is not in front (codehatch never is), so the
/// highlight lagged one movement behind, or waited for a nudge of the mouse. Pointer movements reach codehatch
/// promptly through its event monitors, which is what the notch itself already relies on.
final class PointerTracker: ObservableObject {
    static let panel = PointerTracker(), window = PointerTracker(), menu = PointerTracker()
    @Published private(set) var over: String?
    private var places: [String: CGRect] = [:]
    private var last: CGPoint?
    /// A row moved (the list scrolled, or a session moved up): check again with the pointer where it last was, so the
    /// highlight follows the row under a pointer that has not moved.
    func place(_ id: String, _ rect: CGRect) {
        places[id] = rect
        if let last, rect.contains(last) || over == id { DispatchQueue.main.async { self.pointer(at: self.last) } }
    }
    func forget(_ id: String) { places[id] = nil; if over == id { over = nil } }
    /// The pointer is at this point, in the window's content (top-left origin), or outside the window (nil).
    func pointer(at p: CGPoint?) {
        last = p
        let now = p.flatMap { p in places.first { $0.value.contains(p) }?.key }
        if now != over {
            over = now
            if UserDefaults.standard.bool(forKey: "debugHover") { dbg(String(format: "pointer over %@ %.3f", now ?? "nothing", Date().timeIntervalSince1970)) }
        }
    }
}

/// A row or card that is highlighted while the pointer is over it.
struct Hovering<Content: View>: View {
    let id: String
    var onLeave: () -> Void = {}
    @ViewBuilder let content: (Bool) -> Content
    @EnvironmentObject private var pointer: PointerTracker
    var body: some View {
        content(pointer.over == id)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { pointer.place(id, g.frame(in: .global)) }
                    .onChange(of: g.frame(in: .global)) { _, r in pointer.place(id, r) }
                    .onDisappear { pointer.forget(id) }
            })
            .onChange(of: pointer.over == id) { was, now in if was && !now { onLeave() } }
    }
}
