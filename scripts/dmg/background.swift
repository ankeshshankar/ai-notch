// Draws the disk image window's background: 660 × 420 points, at 1x and 2x.
//   xcrun swiftc -O background.swift -o background && ./background out.png out@2x.png
// The promo's look: a dark gradient with soft orange and purple glows, the wordmark in an
// orange-to-lilac gradient, and an arrow from the app to Applications.
//
// Finder draws the icon labels in black on a light appearance and in white on a dark one, over
// this picture, whatever it shows. So each icon sits on a tile of a middle tone (relative
// luminance about 0.18) where black and white text both read at 4.5:1 or better.
import AppKit
import CoreText

let size = CGSize(width: 660, height: 420)
/// The icons' centres as Finder places them (from the top-left), shared with make-dmg.sh.
let appCentre = CGPoint(x: 170, y: 196)
let applicationsCentre = CGPoint(x: 490, y: 196)

let orange = CGColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)   // #d97757
let purple = CGColor(srgbRed: 0.565, green: 0.522, blue: 0.914, alpha: 1)   // #9085e9
let lilac = CGColor(srgbRed: 0.76, green: 0.72, blue: 0.98, alpha: 1)

func render(scale: CGFloat, to path: String) {
    let width = Int(size.width * scale), height = Int(size.height * scale)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Top-left origin, in points.
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    // The base: a deep violet-black, a touch lighter at the top.
    let base = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.105, green: 0.090, blue: 0.140, alpha: 1),
        CGColor(srgbRed: 0.055, green: 0.047, blue: 0.075, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

    // Soft glows: orange low on the left, purple high on the right.
    func glow(_ colour: CGColor, at centre: CGPoint, radius: CGFloat, alpha: CGFloat) {
        let g = CGGradient(colorsSpace: space, colors: [colour.copy(alpha: alpha)!, colour.copy(alpha: alpha * 0.35)!, colour.copy(alpha: 0)!] as CFArray,
                           locations: [0, 0.45, 1])!
        ctx.drawRadialGradient(g, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: [])
    }
    glow(orange, at: CGPoint(x: 90, y: 430), radius: 330, alpha: 0.42)
    glow(purple, at: CGPoint(x: 600, y: -10), radius: 360, alpha: 0.40)
    glow(purple, at: CGPoint(x: 330, y: 250), radius: 200, alpha: 0.10)

    // The tiles under the icons and their labels.
    for centre in [appCentre, applicationsCentre] {
        let rect = CGRect(x: centre.x - 86, y: centre.y - 80, width: 172, height: 182)
        let tile = CGPath(roundedRect: rect, cornerWidth: 26, cornerHeight: 26, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
        ctx.addPath(tile)
        ctx.setFillColor(CGColor(srgbRed: 0.45, green: 0.43, blue: 0.52, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(tile)
        ctx.clip()
        // A faint sheen at the top; the label band below stays the middle tone.
        let sheen = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.53, green: 0.51, blue: 0.61, alpha: 1),
            CGColor(srgbRed: 0.46, green: 0.44, blue: 0.53, alpha: 1),
            CGColor(srgbRed: 0.45, green: 0.43, blue: 0.52, alpha: 1),
        ] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 25.5, cornerHeight: 25.5, transform: nil))
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22))
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    // The arrow: a gentle arc from the app's tile to Applications', orange to lilac.
    let from = CGPoint(x: appCentre.x + 106, y: appCentre.y)
    let to = CGPoint(x: applicationsCentre.x - 112, y: applicationsCentre.y)
    let arrow = CGMutablePath()
    arrow.move(to: from)
    arrow.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2, y: from.y - 26))
    // The head: two strokes along the curve's end tangent.
    let tangent = atan2(to.y - (from.y - 26), to.x - (from.x + to.x) / 2)
    for side in [-1.0, 1.0] {
        let a = tangent + .pi + side * 0.55
        arrow.move(to: to)
        arrow.addLine(to: CGPoint(x: to.x + 15 * cos(a), y: to.y + 15 * sin(a)))
    }
    ctx.saveGState()
    ctx.addPath(arrow)
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let stroke = CGGradient(colorsSpace: space, colors: [orange, lilac] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(stroke, start: CGPoint(x: from.x, y: 0), end: CGPoint(x: to.x, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // The wordmark, filled with the gradient through its glyph outlines.
    func textPath(_ string: String, size: CGFloat, weight: NSFont.Weight, tracking: CGFloat = 0) -> (CGPath, CGRect) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .kern: tracking])
        let line = CTLineCreateWithAttributedString(attributed)
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for (glyph, position) in zip(glyphs, positions) {
                guard let outline = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
                // Glyphs are y-up; the context is y-down.
                path.addPath(outline, transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: position.x, ty: 0))
            }
        }
        return (path, path.boundingBoxOfPath)
    }
    func draw(_ string: String, size: CGFloat, weight: NSFont.Weight, centreX: CGFloat, baseline: CGFloat,
              tracking: CGFloat = 0, fill: (CGRect) -> Void) {
        let (path, box) = textPath(string, size: size, weight: weight, tracking: tracking)
        let width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .kern: tracking])), nil, nil, nil)
        let placed = CGMutablePath()
        placed.addPath(path, transform: CGAffineTransform(translationX: centreX - width / 2, y: baseline))
        ctx.saveGState()
        ctx.addPath(placed)
        ctx.clip()
        fill(box.offsetBy(dx: centreX - width / 2, dy: baseline))
        ctx.restoreGState()
    }
    let mark = CGGradient(colorsSpace: space, colors: [orange, lilac] as CFArray, locations: [0, 1])!
    draw("AI Notch", size: 30, weight: .bold, centreX: size.width / 2, baseline: 62, tracking: -0.4) { box in
        ctx.drawLinearGradient(mark, start: CGPoint(x: box.minX, y: 0), end: CGPoint(x: box.maxX, y: 0), options: [])
    }
    draw("Drag AI Notch to Applications", size: 14, weight: .medium, centreX: size.width / 2, baseline: 356) { box in
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.80))
        ctx.fill(box.insetBy(dx: -2, dy: -2))
    }
    draw("Then open it from Applications to set it up.", size: 11.5, weight: .regular, centreX: size.width / 2, baseline: 378) { box in
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.52))
        ctx.fill(box.insetBy(dx: -2, dy: -2))
    }

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    // The point size, so tiffutil pairs the 2x as the same picture at double density.
    rep.size = size
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: background <out.png> <out@2x.png>\n".utf8))
    exit(2)
}
render(scale: 1, to: args[1])
render(scale: 2, to: args[2])
