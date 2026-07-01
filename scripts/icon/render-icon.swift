import Cocoa
import CoreGraphics
let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
    bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError() }
func rr(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }

// --- Background: subtle vertical gradient charcoal, squircle mask ---
let bgInset: CGFloat = 60
let bg = CGRect(x: bgInset, y: bgInset, width: S - 2*bgInset, height: S - 2*bgInset)
ctx.saveGState()
ctx.addPath(rr(bg, (S - 2*bgInset)*0.235)); ctx.clip()
let bgGrad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1),
    CGColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// --- Palette: softened toward a common warmth (one family) ---
let red   = CGColor(red: 0.92, green: 0.35, blue: 0.33, alpha: 1)
let blue  = CGColor(red: 0.33, green: 0.56, blue: 0.92, alpha: 1)
let green = CGColor(red: 0.36, green: 0.76, blue: 0.48, alpha: 1)
let lw: CGFloat = 96          // bolder
let corner: CGFloat = 120

// Stroke with a gradient whose transition is centered on `elbow`, tight band so arms
// stay pure color and the blend happens through the curve. Axis runs c0node->c1node.
func strokeElbow(_ path: CGPath, _ c0: CGColor, _ c1: CGColor, from a: CGPoint, elbow e: CGPoint, to b: CGPoint) {
    ctx.saveGState(); ctx.addPath(path)
    ctx.setLineWidth(lw); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    // gradient axis: from a to b, but with the blend band packed around the elbow's
    // projected position. Approximate by using a short axis segment straddling the elbow.
    let dx = b.x - a.x, dy = b.y - a.y
    let len = max(hypot(dx, dy), 1)
    let ux = dx/len, uy = dy/len
    let band: CGFloat = 240   // width of the transition band around the elbow
    let start = CGPoint(x: e.x - ux*band/2, y: e.y - uy*band/2)
    let end   = CGPoint(x: e.x + ux*band/2, y: e.y + uy*band/2)
    let grad = CGGradient(colorsSpace: cs, colors: [c0, c0, c1, c1] as CFArray, locations: [0, 0.30, 0.70, 1])!
    ctx.drawLinearGradient(grad, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
// Straight stroke: blend centered on the geometric midpoint (its "elbow" = middle).
func strokeLine(_ path: CGPath, _ c0: CGColor, _ c1: CGColor, from a: CGPoint, to b: CGPoint) {
    strokeElbow(path, c0, c1, from: a, elbow: CGPoint(x: (a.x+b.x)/2, y: (a.y+b.y)/2), to: b)
}

// Soft shadow lifting strokes off the charcoal.
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
// (shadow applies to each fill; we draw strokes within it)
// To keep shadow but per-shape, wrap each in a transparency layer.

func drawShape(_ body: () -> Void) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.4))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// --- Geometry, shifted left by DX to compensate for the r's shoulder reaching right ---
let DX: CGFloat = -44
// "r" — right. One continuous path: green bottom → up the stem → smoothly curves into
// the shoulder that hooks up-and-right. Single stroke, so the shoulder join is seamless
// (no dimple). Gradient red(top)→green(bottom) runs along the vertical; the shoulder
// sits above the blend band so it stays red.
drawShape {
    let stemX: CGFloat = 700 + DX
    let topY: CGFloat = 690           // where the stem turns into the shoulder (stem shorter here)
    let botY: CGFloat = 252
    let r = CGMutablePath()
    r.move(to: CGPoint(x: stemX, y: botY))                 // green bottom
    r.addLine(to: CGPoint(x: stemX, y: topY))              // up the stem
    r.addQuadCurve(to: CGPoint(x: stemX + 120, y: topY + 78),   // shoulder: out and up to the right
                   control: CGPoint(x: stemX + 6, y: topY + 82))
    // Stroke with the vertical red→green gradient (elbow = stem midpoint of the straight part).
    strokeLine(r, green, red, from: CGPoint(x: stemX, y: botY), to: CGPoint(x: stemX, y: topY))
}
// BEND 1 (top left): red DOWN then blue LEFT. elbow at (556,628).
drawShape {
    let b1 = CGMutablePath()
    b1.move(to: CGPoint(x: 556 + DX, y: 792))
    b1.addLine(to: CGPoint(x: 556 + DX, y: 628 + corner))
    b1.addQuadCurve(to: CGPoint(x: 556 + DX - corner, y: 628), control: CGPoint(x: 556 + DX, y: 628))
    b1.addLine(to: CGPoint(x: 300 + DX, y: 628))
    strokeElbow(b1, red, blue, from: CGPoint(x: 556 + DX, y: 792), elbow: CGPoint(x: 556 + DX, y: 628), to: CGPoint(x: 300 + DX, y: 628))
}
// BEND 2 (bottom left): blue RIGHT then green DOWN. elbow at (556,440).
drawShape {
    let b2 = CGMutablePath()
    b2.move(to: CGPoint(x: 300 + DX, y: 440))
    b2.addLine(to: CGPoint(x: 556 + DX - corner, y: 440))
    b2.addQuadCurve(to: CGPoint(x: 556 + DX, y: 440 - corner), control: CGPoint(x: 556 + DX, y: 440))
    b2.addLine(to: CGPoint(x: 556 + DX, y: 268))
    strokeElbow(b2, blue, green, from: CGPoint(x: 300 + DX, y: 440), elbow: CGPoint(x: 556 + DX, y: 440), to: CGPoint(x: 556 + DX, y: 268))
}

let img = ctx.makeImage()!
let url = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-rachelshu-code-screenmonger/a23cec28-d38f-46b6-90b3-f5d6450676ca/scratchpad/icon_master.png")
let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest); print("ok")
