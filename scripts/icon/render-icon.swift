// Renders the Size Queen app icon master (1024×1024) to scripts/icon/AppIcon_master_1024.png.
// Run from the repo root:  swift scripts/icon/render-icon.swift
// Then rebuild Resources/AppIcon.icns (sips + iconutil; see scripts/package.sh notes).
//
// The look: a hot-pink gradient squircle, a gold three-point crown whose band is a
// tailor's measuring tape (reading 27″, the canonical monitor), and the same four-point
// sparkles the arranger's seams wear. She measures. It's the whole thing.
import Cocoa
import CoreGraphics

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
    bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError() }
func rr(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }

// --- Background: pink→magenta diagonal gradient in the standard squircle ---
let bgInset: CGFloat = 60
let bg = CGRect(x: bgInset, y: bgInset, width: S - 2*bgInset, height: S - 2*bgInset)
ctx.saveGState()
ctx.addPath(rr(bg, (S - 2*bgInset) * 0.235)); ctx.clip()
let bgGrad = CGGradient(colorsSpace: cs, colors: [
    CGColor(srgbRed: 1.00, green: 0.56, blue: 0.80, alpha: 1),   // light pink (top-left light)
    CGColor(srgbRed: 0.98, green: 0.34, blue: 0.72, alpha: 1),   // hot pink
    CGColor(srgbRed: 0.70, green: 0.15, blue: 0.62, alpha: 1),   // deep magenta
] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: bgInset, y: S - bgInset),
                       end: CGPoint(x: S - bgInset, y: bgInset), options: [])
ctx.restoreGState()

// Soft shadow wrapper so the crown lifts off the gradient.
func drawShape(_ body: () -> Void) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
                  color: CGColor(srgbRed: 0.2, green: 0, blue: 0.15, alpha: 0.40))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

let gold = CGColor(srgbRed: 1.00, green: 0.79, blue: 0.24, alpha: 1)

// --- The crown: band + three points with ball tips, rounded joins throughout ---
drawShape {
    ctx.setFillColor(gold)
    ctx.setStrokeColor(gold)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(26)   // stroke the fill outline to round the zigzag corners

    // Body: base at y 372, peaks up to ~712, valleys at 462.
    let body = CGMutablePath()
    body.move(to: CGPoint(x: 312, y: 372))         // base left
    body.addLine(to: CGPoint(x: 332, y: 656))      // left peak
    body.addLine(to: CGPoint(x: 422, y: 462))      // valley
    body.addLine(to: CGPoint(x: 512, y: 712))      // center peak (tallest — obviously)
    body.addLine(to: CGPoint(x: 602, y: 462))      // valley
    body.addLine(to: CGPoint(x: 692, y: 656))      // right peak
    body.addLine(to: CGPoint(x: 712, y: 372))      // base right
    body.closeSubpath()
    ctx.addPath(body); ctx.drawPath(using: .fillStroke)


    // Ball tips on the three points.
    for (x, y) in [(332.0, 672.0), (512.0, 728.0), (692.0, 672.0)] {
        ctx.fillEllipse(in: CGRect(x: x - 28, y: y - 28, width: 56, height: 56))
    }
}

// --- The band is a measuring tape: cream, black ticks, reading 27″ ---
drawShape {
    let tape = CGRect(x: 282, y: 292, width: 460, height: 84)
    ctx.setFillColor(CGColor(srgbRed: 0.99, green: 0.96, blue: 0.86, alpha: 1))   // tailor's cream
    ctx.addPath(rr(tape, 20)); ctx.fillPath()
    // Tick marks off the tape's top edge, tall every fourth; a gap in the middle for the number.
    ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.08, blue: 0.1, alpha: 1))
    var i = 0
    for x in stride(from: tape.minX + 22, through: tape.maxX - 22, by: 21.0) {
        if abs(x - 512) < 74 { i += 1; continue }                     // leave room for "27″"
        let h: CGFloat = (i % 4 == 0) ? 34 : 18
        ctx.fill(CGRect(x: x - 2.5, y: tape.maxY - h, width: 5, height: h))
        i += 1
    }
    // The number. 27 inches: the canonical monitor, and she will be checking.
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 52),
        .foregroundColor: NSColor(srgbRed: 0.1, green: 0.08, blue: 0.1, alpha: 1),
    ]
    let label = NSAttributedString(string: "27″", attributes: attrs)
    let sz = label.size()
    label.draw(at: NSPoint(x: 512 - sz.width / 2, y: tape.midY - sz.height / 2))
}

// --- Sparkles: the seams' four-point star (quad curves pinched through the center) ---
func sparkle(_ c: CGPoint, _ r: CGFloat, _ alpha: CGFloat) {
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
    ctx.move(to: CGPoint(x: c.x, y: c.y + r))
    ctx.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
    ctx.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
    ctx.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
    ctx.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
    ctx.fillPath()
}
sparkle(CGPoint(x: 224, y: 704), 66, 0.95)
sparkle(CGPoint(x: 806, y: 274), 46, 0.85)
sparkle(CGPoint(x: 772, y: 744), 32, 0.70)
sparkle(CGPoint(x: 258, y: 300), 24, 0.60)

let img = ctx.makeImage()!
let url = URL(fileURLWithPath: "scripts/icon/AppIcon_master_1024.png")
let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest); print("ok")
