import AppKit
import QuartzCore

/// GPU-backed seam particles via `CAEmitterLayer` — colored dots born along each seam
/// bar's inward edge, drifting toward the display center and fading out. Core Animation
/// runs the simulation off the main thread on the GPU, so it scales to thousands of
/// particles without touching `draw(_:)` per frame.
///
/// The canvas recomputes bar geometry every `draw(_:)`; it hands us the current set of
/// edges via `begin`/`add`/`commit`, and we create/reposition/retire one emitter layer
/// per edge. Between draws the emitters animate themselves.
@MainActor
final class SeamEmitters {

    /// Which way particles drift (toward the display center) from the bar's inward edge.
    enum Direction { case left, right, up, down }

    private let host: CALayer
    /// Live emitter layers keyed by a stable per-edge id.
    private var layers: [String: CAEmitterLayer] = [:]
    /// Ids seen during the current begin…commit pass (to retire the rest).
    private var seen: Set<String> = []
    /// One shared particle sprite (a soft round dot), tinted per-emitter via `.color`.
    private let sprite: CGImage = SeamEmitters.makeDotSprite()

    init(host: CALayer) {
        self.host = host
    }

    /// Start a geometry pass (called once per `draw(_:)` before the `add` calls).
    func begin() { seen.removeAll(keepingCapacity: true) }

    /// Register/refresh the emitter for one seam edge. `rect` is the bar; `inward` is the
    /// drift direction; `sizeScale` enlarges dots + speed (edge bars vs mini-map bars).
    func add(edgeOf rect: NSRect, direction: Direction, color: NSColor, id: String, sizeScale: CGFloat) {
        seen.insert(id)
        let layer = layers[id] ?? makeEmitter(id: id)

        // Emitter box = a thin rectangle along the seam (spread over its length). Particles
        // fire perpendicular inward via a global `emissionLongitude` (y-up frame). View is
        // y-up: `.up` fires +y (screen top), `.down` −y; `.left` −x, `.right` +x. A small
        // half-height (2) gives the box some depth so `.volume` seeds cleanly.
        let (position, size, angle): (CGPoint, CGSize, CGFloat)
        let long: CGFloat
        switch direction {
        case .left:  position = CGPoint(x: rect.minX, y: rect.midY); size = CGSize(width: 2, height: rect.height); angle = .pi;      long = rect.height
        case .right: position = CGPoint(x: rect.maxX, y: rect.midY); size = CGSize(width: 2, height: rect.height); angle = 0;        long = rect.height
        case .up:    position = CGPoint(x: rect.midX, y: rect.maxY); size = CGSize(width: rect.width, height: 2); angle = .pi / 2;   long = rect.width
        case .down:  position = CGPoint(x: rect.midX, y: rect.minY); size = CGSize(width: rect.width, height: 2); angle = -.pi / 2;  long = rect.width
        }

        // Geometry updates shouldn't animate (they'd lag the layout); wrap in a no-anim
        // transaction.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        layer.emitterPosition = position
        layer.emitterSize = size

        // Travel = speed × lifetime; keep both low so particles die close to the seam. Speed
        // still scales gently with bar size so edge bars aren't a stalled sliver, but far less
        // than before.
        let speed: CGFloat = max(2.5, long * 0.014) * sizeScale
        let dot = layer.emitterCells?.first ?? makeCell()
        dot.contents = sprite
        // The seam color throughout (semi-transparent), no color drift.
        dot.color = color.withAlphaComponent(0.5).cgColor
        dot.redSpeed = 0; dot.greenSpeed = 0; dot.blueSpeed = 0
        dot.birthRate = Float(max(1, long * 1.5))   // longer seam → proportionally more
        dot.velocity = speed
        dot.velocityRange = speed * 0.3
        dot.emissionLongitude = angle               // global inward direction (y-up frame)
        dot.emissionRange = 0.15                     // tight fan → clearly perpendicular
        dot.scale = 0.2 * sizeScale
        dot.scaleRange = 0.08 * sizeScale
        layer.emitterCells = [dot]
        CATransaction.commit()
    }

    /// Finish the pass: retire emitters whose edge no longer exists.
    func commit() {
        for (id, layer) in layers where !seen.contains(id) {
            layer.removeFromSuperlayer()
            layers[id] = nil
        }
    }

    /// Remove everything (arranger closing).
    func clear() {
        layers.values.forEach { $0.removeFromSuperlayer() }
        layers.removeAll()
    }

    private func makeEmitter(id: String) -> CAEmitterLayer {
        let e = CAEmitterLayer()
        // A rectangle emitter spreads births uniformly across its `emitterSize` box on both
        // axes (a thin box along the seam), and `emissionLongitude` fires in the unrotated
        // y-up frame — so no layer rotation, and direction is a plain global angle.
        e.emitterShape = .rectangle
        e.emitterMode = .volume
        e.renderMode = .unordered         // distinct sparkles, no additive blow-out
        e.emitterCells = [makeCell()]
        host.addSublayer(e)
        layers[id] = e
        return e
    }

    private func makeCell() -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.lifetime = 1.0
        cell.lifetimeRange = 0.9          // wide spread: lives ~0.1–1.9s
        cell.alphaSpeed = -0.3            // fade out over life (gentler, since they start semi-transparent)
        cell.scaleSpeed = -0.25           // shrink as they travel (per second, off the initial scale)
        // Color drift (white → seam color) is per-seam, set in `add`.
        cell.velocityRange = 8
        return cell
    }

    /// A four-point sparkle (concave star: tips at N/E/S/W, quad curves pinched through
    /// the center) — the seams don't glow, they *shimmer*.
    private static func makeDotSprite() -> CGImage {
        let size = 32
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let c = CGFloat(size) / 2
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        let r = c - 1
        let center = CGPoint(x: c, y: c)
        ctx.move(to: CGPoint(x: c, y: c + r))                                  // top tip
        ctx.addQuadCurve(to: CGPoint(x: c + r, y: c), control: center)         // → right
        ctx.addQuadCurve(to: CGPoint(x: c, y: c - r), control: center)         // → bottom
        ctx.addQuadCurve(to: CGPoint(x: c - r, y: c), control: center)         // → left
        ctx.addQuadCurve(to: CGPoint(x: c, y: c + r), control: center)         // → close
        ctx.fillPath()
        return ctx.makeImage()!
    }
}
