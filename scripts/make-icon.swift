// Draws the app's icon (the white mark on a near-black rounded square) and writes assets/AppIcon.icns and assets/icon.png.
// Run from anywhere: swift scripts/make-icon.swift
// Run after the mark changes: swift icon/make-icon.swift
import AppKit

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("assets")
guard let mark = NSImage(contentsOf: here.appendingPathComponent("menu-mark.png")) else { fatalError("no mark") }
let set = here.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // The Mac's icon shape: a rounded square a little smaller than the canvas, so it lines up with other apps' icons.
    let box = NSRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let shape = NSBezierPath(roundedRect: box, xRadius: s * 0.18, yRadius: s * 0.18)
    NSColor.black.setFill(); shape.fill()   // plain black: no shading, no edge
    let m = s * 0.50
    mark.draw(in: NSRect(x: (s - m) / 2, y: (s - m) / 2, width: m, height: m), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: set.appendingPathComponent("icon_\(name).png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", here.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: here.appendingPathComponent("icon.png"))
try? FileManager.default.copyItem(at: set.appendingPathComponent("icon_256x256.png"), to: here.appendingPathComponent("icon.png"))
try? FileManager.default.removeItem(at: set)
print(p.terminationStatus == 0 ? "wrote AppIcon.icns" : "iconutil failed")
