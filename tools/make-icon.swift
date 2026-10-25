// Génère Resources/AppIcon.icns : squircle dégradé, fenêtres en cascade.
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let box = NSRect(x: 100*s, y: 100*s, width: 824*s, height: 824*s)
    let shape = NSBezierPath(roundedRect: box, xRadius: 185*s, yRadius: 185*s)

    NSGraphicsContext.current!.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowBlurRadius = 24*s; shadow.shadowOffset = NSSize(width: 0, height: -10*s)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.set()
    NSColor.black.setFill(); shape.fill()
    NSGraphicsContext.current!.restoreGraphicsState()

    NSGradient(colors: [NSColor(red: 0.36, green: 0.42, blue: 1.0, alpha: 1),
                        NSColor(red: 0.62, green: 0.30, blue: 0.95, alpha: 1)])!.draw(in: shape, angle: -60)

    // Reflet en haut (effet verre)
    NSGraphicsContext.current!.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: box.minX, y: box.midY, width: box.width, height: box.height/2), angle: -90)
    NSGraphicsContext.current!.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.35).setStroke()
    let rim = NSBezierPath(roundedRect: box.insetBy(dx: 3*s, dy: 3*s), xRadius: 182*s, yRadius: 182*s)
    rim.lineWidth = 4*s; rim.stroke()

    // Trois fenêtres en cascade et une flèche de bascule
    for (i, a) in [(0, 0.45), (1, 0.7), (2, 0.95)] {
        let off = CGFloat(i) * 70*s
        let r = NSRect(x: box.minX + 170*s + off, y: box.minY + 330*s - off, width: 400*s, height: 300*s)
        NSColor.white.withAlphaComponent(a).setFill()
        NSBezierPath(roundedRect: r, xRadius: 40*s, yRadius: 40*s).fill()
        NSColor(red: 0.30, green: 0.30, blue: 0.75, alpha: a * 0.5).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.maxY - 60*s, width: r.width, height: 60*s), xRadius: 40*s, yRadius: 40*s).fill()
    }
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: box.minX + 200*s, y: box.minY + 200*s))
    arrow.line(to: NSPoint(x: box.minX + 330*s, y: box.minY + 200*s))
    arrow.lineWidth = 34*s; arrow.lineCapStyle = .round
    NSColor.white.setStroke(); arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: box.minX + 300*s, y: box.minY + 250*s))
    head.line(to: NSPoint(x: box.minX + 350*s, y: box.minY + 200*s))
    head.line(to: NSPoint(x: box.minX + 300*s, y: box.minY + 150*s))
    head.lineWidth = 34*s; head.lineCapStyle = .round; head.lineJoinStyle = .round; head.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),
                   ("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    try! render(CGFloat(px)).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
