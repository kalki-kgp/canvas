// Draws the app icon (1024px PNG): a violet tile with a hand-drawn box,
// arrow and circle. Usage: swift make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824px tile centred, ~185px corner radius
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
ctx.addPath(path)
ctx.setFillColor(NSColor(red: 0.41, green: 0.40, blue: 0.86, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(red: 0.50, green: 0.48, blue: 0.95, alpha: 1).cgColor,
    NSColor(red: 0.29, green: 0.28, blue: 0.69, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
ctx.restoreGState()

// sketchy strokes: each shape drawn twice, slightly offset, like rough.js
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

func roughRect(_ r: CGRect, _ jitter: CGFloat) {
    for pass in 0..<2 {
        let j = pass == 0 ? jitter : -jitter * 0.7
        ctx.setLineWidth(pass == 0 ? 30 : 16)
        ctx.setAlpha(pass == 0 ? 1 : 0.55)
        ctx.move(to: CGPoint(x: r.minX + j, y: r.minY - j))
        ctx.addQuadCurve(to: CGPoint(x: r.maxX - j, y: r.minY + j), control: CGPoint(x: r.midX, y: r.minY + j * 2))
        ctx.addQuadCurve(to: CGPoint(x: r.maxX + j, y: r.maxY - j), control: CGPoint(x: r.maxX - j * 2, y: r.midY))
        ctx.addQuadCurve(to: CGPoint(x: r.minX - j, y: r.maxY + j), control: CGPoint(x: r.midX, y: r.maxY - j * 2))
        ctx.addQuadCurve(to: CGPoint(x: r.minX + j, y: r.minY - j), control: CGPoint(x: r.minX + j * 2, y: r.midY))
        ctx.strokePath()
    }
    ctx.setAlpha(1)
}

roughRect(CGRect(x: 230, y: 540, width: 300, height: 220), 7)

// circle
for pass in 0..<2 {
    ctx.setLineWidth(pass == 0 ? 30 : 16)
    ctx.setAlpha(pass == 0 ? 1 : 0.55)
    let d: CGFloat = pass == 0 ? 0 : 9
    ctx.addEllipse(in: CGRect(x: 560 + d, y: 250 - d, width: 230 - d, height: 230 + d))
    ctx.strokePath()
}
ctx.setAlpha(1)

// arrow from box to circle
ctx.setLineWidth(30)
ctx.move(to: CGPoint(x: 470, y: 520))
ctx.addQuadCurve(to: CGPoint(x: 600, y: 440), control: CGPoint(x: 560, y: 520))
ctx.strokePath()
ctx.move(to: CGPoint(x: 548, y: 452))
ctx.addLine(to: CGPoint(x: 604, y: 436))
ctx.addLine(to: CGPoint(x: 600, y: 494))
ctx.strokePath()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
