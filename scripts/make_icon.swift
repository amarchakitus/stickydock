// Draws the StickyDock app icon and writes an .iconset directory.
// Usage: swift scripts/make_icon.swift <output.iconset>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // Background tile (macOS icon grid: 824pt tile centered in 1024 canvas).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor.black.setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.55, blue: 1.00, alpha: 1),
               ending: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.78, alpha: 1))!
        .draw(in: tilePath, angle: -90)

    // Monitor.
    let screen = CGRect(x: 212, y: 330, width: 600, height: 400)
    let bezel = NSBezierPath(roundedRect: screen, xRadius: 36, yRadius: 36)
    NSColor.white.setFill()
    bezel.fill()
    let inner = NSBezierPath(roundedRect: screen.insetBy(dx: 24, dy: 24), xRadius: 16, yRadius: 16)
    NSGradient(starting: NSColor(calibratedRed: 0.85, green: 0.91, blue: 1.0, alpha: 1),
               ending: NSColor(calibratedRed: 0.70, green: 0.80, blue: 1.0, alpha: 1))!
        .draw(in: inner, angle: -90)

    // Stand.
    NSColor.white.setFill()
    NSBezierPath(rect: CGRect(x: 482, y: 262, width: 60, height: 70)).fill()
    NSBezierPath(roundedRect: CGRect(x: 392, y: 236, width: 240, height: 36), xRadius: 18, yRadius: 18).fill()

    // Dock bar with app dots.
    let dock = CGRect(x: 332, y: 372, width: 360, height: 64)
    NSColor(calibratedWhite: 1, alpha: 0.85).setFill()
    NSBezierPath(roundedRect: dock, xRadius: 22, yRadius: 22).fill()
    let dotColors: [NSColor] = [.systemRed, .systemOrange, .systemGreen, .systemBlue, .systemPurple]
    for (i, color) in dotColors.enumerated() {
        color.setFill()
        let x = dock.minX + 30 + CGFloat(i) * 64
        NSBezierPath(roundedRect: CGRect(x: x, y: dock.minY + 12, width: 44, height: 40), xRadius: 10, yRadius: 10).fill()
    }

    // Pin holding the dock in place.
    if let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 190, weight: .bold)) {
        let tinted = NSImage(size: pin.size, flipped: false) { r in
            pin.draw(in: r)
            NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.23, alpha: 1).set()
            r.fill(using: .sourceAtop)
            return true
        }
        let w = pin.size.width, h = pin.size.height
        ctx.saveGState()
        ctx.translateBy(x: 700, y: 400)
        ctx.rotate(by: -.pi / 8)
        NSGraphicsContext.saveGraphicsState()
        let pinShadow = NSShadow()
        pinShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        pinShadow.shadowOffset = NSSize(width: 0, height: -8)
        pinShadow.shadowBlurRadius = 12
        pinShadow.set()
        tinted.draw(in: CGRect(x: -w / 2, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = drawIcon(size: CGFloat(base * scale))
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    }
}
