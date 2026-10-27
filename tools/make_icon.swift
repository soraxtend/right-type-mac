// Draws the app icon and writes app/AppIcon.icns.
//   swift tools/make_icon.swift            (from the project folder)
//   swift tools/make_icon.swift preview.png  also writes a 1024px PNG
import AppKit

let blue = NSColor(srgbRed: 0.247, green: 0.435, blue: 0.820, alpha: 1)   // #3F6FD1, RightType's colour
let ink = NSColor(srgbRed: 0.122, green: 0.149, blue: 0.200, alpha: 1)    // #1F2633

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
}

/// The icon on a 1024-point canvas, in the macOS layout (an 824-point tile
/// with room for its shadow).
func draw(in ctx: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Soft shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28,
                  color: NSColor.black.withAlphaComponent(0.22).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // White to a faint cool grey, top to bottom.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1).cgColor,
        NSColor(srgbRed: 0.925, green: 0.937, blue: 0.957, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    ctx.restoreGState()

    // Hairline edge.
    ctx.addPath(shape)
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.06).cgColor)
    ctx.setLineWidth(2)
    ctx.strokePath()

    // "A" and "ก" side by side, sharing a baseline.
    let latin = NSAttributedString(string: "A", attributes: [.font: rounded(400, .semibold), .foregroundColor: ink])
    let thai = NSAttributedString(string: "ก", attributes: [
        .font: NSFont(name: "SukhumvitSet-SemiBold", size: 430) ?? rounded(430, .bold), .foregroundColor: blue])
    let gap: CGFloat = 18
    let width = latin.size().width + gap + thai.size().width
    let baseline: CGFloat = 440
    let x = tile.midX - width / 2
    let g = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g
    latin.draw(at: NSPoint(x: x, y: baseline + rounded(400, .semibold).descender))
    thai.draw(at: NSPoint(x: x + latin.size().width + gap,
                          y: baseline + (NSFont(name: "SukhumvitSet-SemiBold", size: 430)?.descender ?? 0)))
    NSGraphicsContext.restoreGraphicsState()

    // A swap mark under the letters: two short opposed arrows.
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(19)
    func arrow(from: CGFloat, to: CGFloat, y: CGFloat, color: NSColor) {
        ctx.setStrokeColor(color.cgColor)
        ctx.move(to: CGPoint(x: from, y: y))
        ctx.addLine(to: CGPoint(x: to, y: y))
        let dir: CGFloat = to > from ? 1 : -1
        ctx.move(to: CGPoint(x: to - 34 * dir, y: y + 30))
        ctx.addLine(to: CGPoint(x: to, y: y))
        ctx.addLine(to: CGPoint(x: to - 34 * dir, y: y - 30))
        ctx.strokePath()
    }
    arrow(from: 392, to: 632, y: 338, color: ink.withAlphaComponent(0.85))
    arrow(from: 632, to: 392, y: 270, color: blue)
}

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    ctx.interpolationQuality = .high
    draw(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try! png(pt).write(to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try! png(pt * 2).write(to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", set.path, "-o", "app/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
if CommandLine.arguments.count > 1 {
    try! png(1024).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
print(task.terminationStatus == 0 ? "Wrote app/AppIcon.icns" : "iconutil failed")
