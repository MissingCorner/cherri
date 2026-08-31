// Renders the Cherri app icon: dark squircle, pulse rings, blue/green
// visualizer arcs, and a red cherry-orb with a stem and a small waveform.
// Usage: swift scripts/render-icon.swift  →  App/Resources/AppIcon.icns
import AppKit

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func render(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(px)

    // Background squircle on the standard macOS icon grid.
    let inset = s * 0.098
    let bgRect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = bgRect.width * 0.225
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: corner, yRadius: corner)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.22, alpha: 1),
        NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.10, alpha: 1),
    ])!.draw(in: bg, angle: -90)
    bg.addClip()

    let center = NSPoint(x: s / 2, y: s / 2 - s * 0.03)

    // Pulse rings.
    for (radius, alpha) in [(0.21, 0.14), (0.27, 0.09), (0.33, 0.055)] {
        let r = s * CGFloat(radius)
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        ring.lineWidth = max(s * 0.006, 1)
        NSColor.white.withAlphaComponent(CGFloat(alpha)).setStroke()
        ring.stroke()
    }

    // Visualizer arcs on the middle ring: blue left (meeting), green right (you).
    let arcRadius = s * 0.27
    func arc(_ from: CGFloat, _ to: CGFloat, _ color: NSColor) {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: arcRadius, startAngle: from, endAngle: to)
        path.lineWidth = s * 0.028
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }
    arc(150, 210, NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.95, alpha: 0.9))
    arc(-30, 30, NSColor(calibratedRed: 0.30, green: 0.75, blue: 0.45, alpha: 0.9))

    // Cherry stem (drawn behind the orb top).
    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: center.x + s * 0.01, y: center.y + s * 0.12))
    stem.curve(to: NSPoint(x: center.x + s * 0.085, y: center.y + s * 0.235),
               controlPoint1: NSPoint(x: center.x + s * 0.005, y: center.y + s * 0.19),
               controlPoint2: NSPoint(x: center.x + s * 0.035, y: center.y + s * 0.225))
    stem.lineWidth = s * 0.022
    stem.lineCapStyle = .round
    NSColor(calibratedRed: 0.38, green: 0.66, blue: 0.38, alpha: 1).setStroke()
    stem.stroke()

    // Leaf.
    let leaf = NSBezierPath()
    let leafBase = NSPoint(x: center.x + s * 0.085, y: center.y + s * 0.235)
    leaf.move(to: leafBase)
    leaf.curve(to: NSPoint(x: leafBase.x + s * 0.085, y: leafBase.y + s * 0.02),
               controlPoint1: NSPoint(x: leafBase.x + s * 0.03, y: leafBase.y + s * 0.045),
               controlPoint2: NSPoint(x: leafBase.x + s * 0.065, y: leafBase.y + s * 0.045))
    leaf.curve(to: leafBase,
               controlPoint1: NSPoint(x: leafBase.x + s * 0.06, y: leafBase.y - s * 0.005),
               controlPoint2: NSPoint(x: leafBase.x + s * 0.025, y: leafBase.y - s * 0.005))
    NSColor(calibratedRed: 0.38, green: 0.66, blue: 0.38, alpha: 1).setFill()
    leaf.fill()

    // Cherry orb.
    let orbR = s * 0.145
    let orbRect = NSRect(x: center.x - orbR, y: center.y - orbR, width: orbR * 2, height: orbR * 2)
    let orb = NSBezierPath(ovalIn: orbRect)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.38, alpha: 1),
        NSColor(calibratedRed: 0.72, green: 0.10, blue: 0.20, alpha: 1),
    ])!.draw(in: orb, angle: -75)

    // Soft highlight.
    let hlR = orbR * 0.55
    let hl = NSBezierPath(ovalIn: NSRect(x: center.x - orbR * 0.55, y: center.y + orbR * 0.05,
                                         width: hlR, height: hlR * 0.8))
    NSColor.white.withAlphaComponent(0.18).setFill()
    hl.fill()

    // Waveform bars inside the orb.
    let barW = s * 0.026
    let gaps = s * 0.052
    let heights: [CGFloat] = [0.09, 0.155, 0.075]
    for (i, hFrac) in heights.enumerated() {
        let x = center.x - gaps + CGFloat(i) * gaps - barW / 2
        let h = s * hFrac
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: center.y - h / 2, width: barW, height: h),
                               xRadius: barW / 2, yRadius: barW / 2)
        NSColor.white.withAlphaComponent(0.92).setFill()
        bar.fill()
    }

    return rep
}

let fm = FileManager.default
let iconset = "build/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for (name, px) in sizes {
    let rep = render(px: px)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}

let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconset, "-o", "App/Resources/AppIcon.icns"]
task.launch()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote App/Resources/AppIcon.icns" : "iconutil failed")
