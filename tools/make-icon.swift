// Renders Peaky's app icon (a dark squircle with a glowing island) into an .iconset.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.32, alpha: 1),
                        NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.09, alpha: 1)])!
        .draw(in: squircle, angle: -90)
    // the island
    let iw = body.width * 0.62, ih = body.width * 0.2
    let island = NSRect(x: body.midX - iw / 2, y: body.maxY - ih - body.height * 0.2, width: iw, height: ih)
    let glow = NSShadow()
    glow.shadowColor = NSColor(calibratedRed: 0.45, green: 0.6, blue: 1, alpha: 0.9)
    glow.shadowBlurRadius = s * 0.05
    glow.set()
    NSColor.black.setFill()
    NSBezierPath(roundedRect: island, xRadius: ih / 2, yRadius: ih / 2).fill()
    NSShadow().set()
    // album dot + bars
    let d = ih * 0.6
    NSGradient(colors: [.systemPink, .systemOrange])!.draw(in: NSBezierPath(ovalIn: NSRect(x: island.minX + ih * 0.22, y: island.midY - d / 2, width: d, height: d)), angle: 45)
    NSColor.systemPink.setFill()
    let bw = ih * 0.11
    for (i, f) in [0.45, 0.8, 0.6, 0.35].enumerated() {
        let bh = ih * 0.6 * CGFloat(f)
        let x = island.maxX - ih * 0.3 - CGFloat(4 - i) * bw * 1.7
        NSBezierPath(roundedRect: NSRect(x: x, y: island.midY - bh / 2, width: bw, height: bh), xRadius: bw / 2, yRadius: bw / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
