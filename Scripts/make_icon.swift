// Renders the app icon (a water drop on a rounded square) into an .iconset folder.
// Usage: swift Scripts/make_icon.swift <output.iconset>
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("gebruik: make_icon.swift <map.iconset>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("kan \(output.path) niet maken: \(error)\n".utf8))
    exit(1)
}

func render(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let s = CGFloat(size)

    // Squircle-ish background with the standard macOS icon margin.
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0.07, green: 0.20, blue: 0.45, alpha: 1),
                        NSColor(srgbRed: 0.18, green: 0.56, blue: 0.86, alpha: 1)])?.draw(in: tilePath, angle: 90)

    // A small "window" at the top that melts into the drop.
    let window = NSRect(x: tile.minX + tile.width * 0.2, y: tile.minY + tile.height * 0.62,
                        width: tile.width * 0.6, height: tile.height * 0.22)
    NSColor.white.withAlphaComponent(0.9).setFill()
    NSBezierPath(roundedRect: window, xRadius: s * 0.025, yRadius: s * 0.025).fill()
    let dots: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
    for (i, color) in dots.enumerated() {
        color.setFill()
        let d = window.height * 0.2
        NSBezierPath(ovalIn: NSRect(x: window.minX + d * (0.7 + CGFloat(i) * 1.5), y: window.maxY - d * 1.6, width: d, height: d)).fill()
    }

    // The drop.
    let cx = tile.midX
    let bottom = tile.minY + tile.height * 0.12
    let r = tile.width * 0.2
    let drop = NSBezierPath()
    drop.move(to: NSPoint(x: cx, y: window.minY + s * 0.02))
    drop.curve(to: NSPoint(x: cx + r, y: bottom + r),
               controlPoint1: NSPoint(x: cx + r * 0.25, y: window.minY - r * 0.4),
               controlPoint2: NSPoint(x: cx + r, y: bottom + r * 1.6))
    drop.appendArc(withCenter: NSPoint(x: cx, y: bottom + r), radius: r, startAngle: 0, endAngle: 180, clockwise: true)
    drop.curve(to: NSPoint(x: cx, y: window.minY + s * 0.02),
               controlPoint1: NSPoint(x: cx - r, y: bottom + r * 1.6),
               controlPoint2: NSPoint(x: cx - r * 0.25, y: window.minY - r * 0.4))
    drop.close()
    NSGradient(colors: [NSColor(srgbRed: 0.55, green: 0.90, blue: 1.0, alpha: 1),
                        NSColor(srgbRed: 0.10, green: 0.55, blue: 0.95, alpha: 1)])?.draw(in: drop, angle: -90)
    NSColor.white.withAlphaComponent(0.55).setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - r * 0.55, y: bottom + r * 0.95, width: r * 0.35, height: r * 0.55)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in sizes {
    guard let data = render(size: size) else {
        FileHandle.standardError.write(Data("renderen van \(name) mislukt\n".utf8))
        exit(1)
    }
    do {
        try data.write(to: output.appendingPathComponent("\(name).png"))
    } catch {
        FileHandle.standardError.write(Data("schrijven van \(name) mislukt: \(error)\n".utf8))
        exit(1)
    }
}
print("icoon gemaakt in \(output.path)")
