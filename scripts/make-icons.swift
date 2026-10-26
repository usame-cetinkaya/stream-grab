// Draws the app and extension icons. Run: swift scripts/make-icons.swift
import AppKit

func draw(_ px: Int, rounded: Bool) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // macOS icons keep a margin around the rounded square; toolbar icons use the full canvas.
    let inset = rounded ? s * 0.1 : 0
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1).cgColor, NSColor(red: 0.11, green: 0.31, blue: 0.85, alpha: 1).cgColor]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    // Down arrow over a tray line.
    let u = rect.width / 100
    let ox = rect.minX, oy = rect.minY
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(10 * u)
    ctx.move(to: CGPoint(x: ox + 50 * u, y: oy + 80 * u)); ctx.addLine(to: CGPoint(x: ox + 50 * u, y: oy + 36 * u))
    ctx.move(to: CGPoint(x: ox + 30 * u, y: oy + 52 * u)); ctx.addLine(to: CGPoint(x: ox + 50 * u, y: oy + 32 * u)); ctx.addLine(to: CGPoint(x: ox + 70 * u, y: oy + 52 * u))
    ctx.move(to: CGPoint(x: ox + 26 * u, y: oy + 20 * u)); ctx.addLine(to: CGPoint(x: ox + 74 * u, y: oy + 20 * u))
    ctx.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base, rounded: true).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2, rounded: true).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
for size in [16, 32, 48, 128] {
    try! draw(size, rounded: false).write(to: URL(fileURLWithPath: "Extension/icons/\(size).png"))
}
print("Icons written.")
