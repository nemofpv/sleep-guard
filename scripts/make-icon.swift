// Turns square artwork into the app icon master, Resources/AppIcon.png (1024×1024).
// The artwork is clipped to the rounded shape macOS icons use and inset on a transparent
// canvas with the usual soft shadow, so it sits correctly next to other icons in Finder.
// build.sh makes the .icns from the result; rerun this only when the artwork changes.
//
// Usage: swift scripts/make-icon.swift Resources/icon-source.jpg Resources/AppIcon.png [zoom]
//
// `zoom` enlarges the artwork inside the icon shape, cropping its margins towards `focus`.
// 1 shows the whole image; the default is what the committed icon was made with.

import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let defaultZoom = 1.3
/// The centre of the subject, as fractions of the artwork measured from its top-left corner.
let focus = CGPoint(x: 0.5, y: 0.43)

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4 else { fail("usage: swift make-icon.swift <artwork> <out.png> [zoom]") }
guard let zoom = args.count == 4 ? Double(args[3]) : defaultZoom, zoom >= 1 else { fail("zoom must be a number, 1 or more") }

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(args[1])") }
guard artwork.width == artwork.height else { fail("artwork must be square, got \(artwork.width)×\(artwork.height)") }

let canvas = 1024
guard let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("cannot create canvas") }

// Apple's icon grid: an 824 px shape centred on the 1024 px canvas.
let box = CGRect(x: 100, y: 100, width: 824, height: 824)

// A superellipse with exponent 5 follows the continuous-corner icon outline closely
// (it meets the 185 px-radius rounded rectangle to within a pixel at the diagonals).
let shape = CGMutablePath()
let exponent = 5.0
let steps = 720
for i in 0..<steps {
    let t = Double(i) / Double(steps) * 2 * Double.pi
    let c = cos(t), s = sin(t)
    let point = CGPoint(x: box.midX + box.width / 2 * CGFloat(copysign(pow(abs(c), 2 / exponent), c)),
                        y: box.midY + box.height / 2 * CGFloat(copysign(pow(abs(s), 2 / exponent), s)))
    if i == 0 { shape.move(to: point) } else { shape.addLine(to: point) }
}
shape.closeSubpath()

// The shadow is cast by the clipped artwork itself, so no fill colour bleeds at the edge.
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(gray: 0, alpha: 0.3))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.addPath(shape)
ctx.clip()
ctx.interpolationQuality = .high
// The zoomed artwork is placed so that `focus` sits at the centre of the shape, then nudged
// back if that would leave part of the shape uncovered.
let drawn = CGSize(width: box.width * CGFloat(zoom), height: box.height * CGFloat(zoom))
let x = min(box.minX, max(box.maxX - drawn.width, box.midX - focus.x * drawn.width))
let y = min(box.minY, max(box.maxY - drawn.height, box.midY - (1 - focus.y) * drawn.height))
ctx.draw(artwork, in: CGRect(origin: CGPoint(x: x, y: y), size: drawn))
ctx.endTransparencyLayer()

guard let icon = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil)
else { fail("cannot write \(args[2])") }
CGImageDestinationAddImage(destination, icon, nil)
guard CGImageDestinationFinalize(destination) else { fail("cannot write \(args[2])") }
print("Wrote \(args[2])")
