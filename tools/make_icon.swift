import AppKit
import Foundation

// Draws the Cantus icon: a dark rounded tile with a signal whose pitch rises
// left to right — sparse on the left, tight on the right. That is the one thing
// this app is really about (changing a track's rate), it is not the PiBridge
// trace, and it still reads at 16 px because the stroke is one continuous
// ribbon at constant amplitude.
//
// The glyph is inset to the usual macOS content box: the ink never comes closer
// than ~7% of the canvas to the tile edge, or it looks crowded next to other
// icons in the Dock.
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

// Tile: 824 pt rounded rect on the 1024 grid, as macOS expects.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
NSGradient(colors: [
    NSColor(srgbRed: 0.085, green: 0.095, blue: 0.125, alpha: 1),
    NSColor(srgbRed: 0.026, green: 0.030, blue: 0.042, alpha: 1),
])!.draw(in: tilePath, angle: -90)
NSColor.white.withAlphaComponent(0.09).setStroke()
tilePath.lineWidth = 3
tilePath.stroke()

// Glyph box: 632 pt wide, so the 60 pt stroke leaves a 74 pt margin inside the
// tile — 7.2% of the canvas, in line with other app icons.
let x0: CGFloat = 196
let x1: CGFloat = 828
let span = x1 - x0
let midY: CGFloat = 512
let amp: CGFloat = 238

// A chirp: frequency climbs from `startCycles` to `endCycles` across the span.
// Phase is the integral, so the spacing changes smoothly instead of stepping.
let startCycles: CGFloat = 0.75
let endCycles: CGFloat = 3.4
let totalCycles = (startCycles + endCycles) / 2

func curveY(_ t: CGFloat) -> CGFloat {
    // t in 0...1 along the span; local frequency = start + (end-start)*t
    let phase = 2 * CGFloat.pi * (startCycles * t + (endCycles - startCycles) * t * t / 2)
    return midY + amp * sin(phase)
}

// Axis: the zero line, so the wave reads as a signal on a scale rather than a
// squiggle. Thin and dim — it must not compete with the stroke at small sizes.
let axis = NSBezierPath()
axis.move(to: NSPoint(x: x0 - 30, y: midY))
axis.line(to: NSPoint(x: x1 + 30, y: midY))
axis.lineWidth = 6
axis.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.22).setStroke()
axis.stroke()

let curve = NSBezierPath()
curve.lineWidth = 60
curve.lineCapStyle = .round
curve.lineJoinStyle = .round
curve.move(to: NSPoint(x: x0, y: curveY(0)))
// Step fine enough near the tight end: the last cycle is ~100 pt, so 2 pt
// samples keep it smooth without making the path huge.
let steps = 640
for i in 1...steps {
    let t = CGFloat(i) / CGFloat(steps)
    curve.line(to: NSPoint(x: x0 + span * t, y: curveY(t)))
}
accent.setStroke()
curve.stroke()

// One soft glow pass, drawn under a shadow rather than re-stroking the path at
// partial alpha (which would just double the opacity).
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 22, color: accent.withAlphaComponent(0.40).cgColor)
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
_ = totalCycles
print("wrote \(outPath)")
