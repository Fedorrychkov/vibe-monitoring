#!/usr/bin/env swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func render(_ pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 198, yRadius: 198)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(calibratedRed: 0.29, green: 0.22, blue: 0.79, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.31, green: 0.23, blue: 0.90, alpha: 1),
                              ending: NSColor(calibratedRed: 0.60, green: 0.43, blue: 1, alpha: 1))!
    gradient.draw(in: tile, angle: 70)
    NSColor.white.withAlphaComponent(0.24).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    let pulse = NSBezierPath()
    pulse.move(to: NSPoint(x: 232, y: 490))
    for point in [NSPoint(x: 350, y: 490), NSPoint(x: 423, y: 690), NSPoint(x: 503, y: 330),
                  NSPoint(x: 578, y: 590), NSPoint(x: 631, y: 490), NSPoint(x: 792, y: 490)] {
        pulse.line(to: point)
    }
    pulse.lineWidth = 62
    pulse.lineCapStyle = .round
    pulse.lineJoinStyle = .round
    NSColor.white.setStroke()
    pulse.stroke()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon rendering failed") }
    return data
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try render(size * scale).write(to: iconset.appendingPathComponent(name))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", iconset.path, "--output", root.appendingPathComponent("Assets/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
try render(512).write(to: root.appendingPathComponent("docs/app-icon.png"))
