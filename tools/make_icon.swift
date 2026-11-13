import AppKit
import Foundation

// Draws the Cantus icon: a dark rounded tile with one continuous sine above a
// row of sample needles whose envelope follows it — a signal, and the samples
// that reconstruct it. Rendered at 1024 and downsampled by make_icon.sh.
//
// usage: make_icon <out.png>

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "icon.png"

// Violet: distinct from PiBridge (blue) and PiBridge 2 (amber) in the Dock.
let accent = NSColor(srgbRed: 0.63, green: 0.53, blue: 0.96, alpha: 1)

let side = 1024
let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
ctx.setAllowsAntialiasing(true)

// Tile
let tile = NSRect(x: 92, y: 92, width: 840, height: 840)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 196, yRadius: 196)
NSGradient(colors: [
    NSColor(srgbRed: 0.085, green: 0.095, blue: 0.125, alpha: 1),
    NSColor(srgbRed: 0.026, green: 0.030, blue: 0.042, alpha: 1),
])!.draw(in: tilePath, angle: -90)
NSColor.white.withAlphaComponent(0.09).setStroke()
tilePath.lineWidth = 3
tilePath.stroke()

// The mark: one bold sine cycle centred on an axis. PiBridge owns the
// PCM-to-DSD trace; this is the thing that does the resampling, so the clean
// continuous signal is the honest mark — and at 16 px a single thick stroke is
// the only shape that survives.
let x0: CGFloat = 164
let x1: CGFloat = 860
let span = x1 - x0
let midY: CGFloat = 512
let amp: CGFloat = 252

func sineY(_ x: CGFloat) -> CGFloat {
    let phase = 2 * CGFloat.pi * (x - x0) / span
    return midY + amp * sin(phase)
}

// Axis, so the curve reads as a signal on a scale rather than a squiggle.
let axis = NSBezierPath()
axis.move(to: NSPoint(x: x0 - 26, y: midY))
axis.line(to: NSPoint(x: x1 + 26, y: midY))
axis.lineWidth = 7
axis.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.18).setStroke()
axis.stroke()

let curve = NSBezierPath()
curve.lineWidth = 68
curve.lineCapStyle = .round
curve.lineJoinStyle = .round
curve.move(to: NSPoint(x: x0, y: sineY(x0)))
var x = x0
while x <= x1 {
    curve.line(to: NSPoint(x: x, y: sineY(x)))
    x += 3
}
accent.setStroke()
curve.stroke()

// Glow under the stroke so it holds up on a light wallpaper.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 26, color: accent.withAlphaComponent(0.45).cgColor)
accent.withAlphaComponent(0.45).setStroke()
curve.stroke()
ctx.restoreGState()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not render icon\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
