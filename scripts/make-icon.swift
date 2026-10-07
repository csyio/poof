// Draws Poof's app icon: a puff of smoke breaking up over a violet-to-blue tile.
// Usage: swift scripts/make-icon.swift <output-dir>   (writes AppIcon.png at 1024 px)
import AppKit

let size: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
// Draw into an exact 1024 px bitmap; NSImage.lockFocus would double it on Retina screens.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext

// macOS icon grid: an 824 pt rounded tile centred on the 1024 canvas, with a soft shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
context.addPath(tilePath)
context.setFillColor(NSColor.black.cgColor)
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(tilePath)
context.clip()
let colors = [NSColor(red: 0.47, green: 0.27, blue: 0.96, alpha: 1).cgColor,
              NSColor(red: 0.16, green: 0.55, blue: 0.98, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

// The puff: overlapping circles forming a cloud, fading toward the upper right where it breaks up.
func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ alpha: CGFloat) {
    context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
    context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}
let cloud: [(CGFloat, CGFloat, CGFloat)] = [
    (360, 430, 120), (470, 470, 150), (590, 440, 125), (420, 380, 105), (540, 380, 115), (650, 400, 85),
]
for (x, y, r) in cloud { circle(x, y, r, 1) }
// Fragments drifting away, smaller and fainter.
let fragments: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (690, 560, 58, 0.9), (770, 640, 40, 0.75), (720, 700, 28, 0.6), (820, 720, 20, 0.45),
    (640, 650, 24, 0.7), (790, 560, 22, 0.6), (850, 630, 12, 0.4),
]
for (x, y, r, a) in fragments { circle(x, y, r, a) }

// Sparkles: four-pointed stars.
func sparkle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: x, y: y + r))
    path.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x, y: y))
    path.addQuadCurve(to: CGPoint(x: x, y: y - r), control: CGPoint(x: x, y: y))
    path.addQuadCurve(to: CGPoint(x: x - r, y: y), control: CGPoint(x: x, y: y))
    path.addQuadCurve(to: CGPoint(x: x, y: y + r), control: CGPoint(x: x, y: y))
    context.addPath(path)
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()
}
sparkle(300, 650, 52)
sparkle(240, 560, 26)
sparkle(860, 820, 30)
context.restoreGState()
NSGraphicsContext.current = nil

try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("AppIcon.png"))
