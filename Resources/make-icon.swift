// Draws Resources/app-icon.icns. Run via ./Resources/make-icon.sh — kept in the repo so the
// icon can be tweaked and regenerated instead of being an opaque binary.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024.0
let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}

// macOS icon geometry: the art sits in a squircle inset from the canvas edge.
let inset = 100.0
let box = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let squircle = CGPath(roundedRect: box, cornerWidth: 190, cornerHeight: 190, transform: nil)

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let gradient = CGGradient(colorsSpace: space,
                          colors: [rgb(37, 60, 214), rgb(126, 34, 206), rgb(190, 24, 160)] as CFArray,
                          locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: box.minX, y: box.maxY),
                       end: CGPoint(x: box.maxX, y: box.minY), options: [])

// Play triangle, optically centred (a shade right of true centre so it reads as balanced).
let c = CGPoint(x: box.midX + 55, y: box.midY + 20)
func triangle(_ r: Double) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x + r, y: c.y))
    p.addLine(to: CGPoint(x: c.x - r * 0.55, y: c.y + r * 0.9))
    p.addLine(to: CGPoint(x: c.x - r * 0.55, y: c.y - r * 0.9))
    p.closeSubpath()
    return p
}

// Broadcast arcs radiating from the lower-left corner — the "stream" half of the mark.
// Knocked out around the triangle (even-odd) so the two marks stay legible at 32px.
let keepOut = CGMutablePath()
keepOut.addPath(squircle)
keepOut.addPath(triangle(255))
ctx.addPath(keepOut)
ctx.clip(using: .evenOdd)

let origin = CGPoint(x: box.minX + 120, y: box.minY + 120)
ctx.setStrokeColor(rgb(255, 255, 255, 0.3))
ctx.setLineCap(.round)
for radius in [230.0, 350.0, 470.0] {
    ctx.setLineWidth(34)
    ctx.addArc(center: origin, radius: radius, startAngle: .pi * 0.17, endAngle: .pi * 0.55, clockwise: false)
    ctx.strokePath()
}
ctx.setFillColor(rgb(255, 255, 255, 0.92))
ctx.fillEllipse(in: CGRect(x: origin.x - 40, y: origin.y - 40, width: 80, height: 80))
ctx.restoreGState()

ctx.setFillColor(rgb(255, 255, 255))
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgb(0, 0, 0, 0.35))
ctx.addPath(triangle(205))
ctx.fillPath()

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
