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
    /// Live emitter layers keyed by a stable per-edge id. Each seam is tiled with fixed-size
    /// generator segments along its length (one `CAEmitterLayer` per segment — a single box
    /// can't vary birth rate along its length): a longer bar gets *more generators*, not
    /// bigger/faster sparkles, so the look is identical on every bar.
    private var layers: [String: [CAEmitterLayer]] = [:]
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
    /// drift direction; `sizeScale` enlarges dots + speed (edge bars vs mini-map bars);
    /// `travelBoost` stretches *only* how far sparkles drift — via longer lifetimes at the
    /// same speed (a slow, deep drift), with fade/shrink rates stretched to match — leaving
    /// size/spacing/density alone (the edge bars want a deeper on-glass drift, not bigger dots).
    func add(edgeOf rect: NSRect, direction: Direction, color: NSColor, id: String,
             sizeScale: CGFloat, travelBoost: CGFloat = 1) {
        seen.insert(id)
        // The seam runs along one axis; particles fire perpendicular inward via a global
        // `emissionLongitude` (y-up frame). View is y-up: `.up` fires +y (screen top), `.down`
        // −y; `.left` −x, `.right` +x. `vertical` = seam runs along y (left/right drift).
        let vertical = (direction == .left || direction == .right)
        let long = vertical ? rect.height : rect.width
        // Fixed-size generators, more or fewer with bar length: each segment covers roughly
        // `segTarget` of seam, so the sparkle *look* (size, speed, density per length) is the
        // same on every bar — only the generator count varies with how long the bar is.
        let segTarget: CGFloat = 14 * sizeScale
        let count = max(1, min(24, Int((long / segTarget).rounded())))
        let segs = segments(id: id, count: count)
        let angle: CGFloat
        switch direction { case .left: angle = .pi; case .right: angle = 0; case .up: angle = .pi / 2; case .down: angle = -.pi / 2 }

        // Seed the sparkles slightly *before* the seam (on its outer side) so they're born a
        // touch off-screen and drift in through the edge, rather than popping into existence
        // right at it. Offset the seam-line coordinate outward (opposite the drift) — no change
        // to speed/lifetime, so travel distance is unchanged, just shifted.
        let backset: CGFloat = 4 * sizeScale
        let lineCoord: CGFloat   // the fixed (perpendicular) coordinate of the emitter line
        switch direction {
        case .left:  lineCoord = rect.minX + backset
        case .right: lineCoord = rect.maxX - backset
        case .up:    lineCoord = rect.maxY - backset
        case .down:  lineCoord = rect.minY + backset
        }

        // Travel = speed × lifetime; both are look constants (speed scaled per context by
        // `sizeScale`, lifetime stretched by `travelBoost`), *not* a function of bar length —
        // a long seam gets more generators, never faster or farther-flying sparkles.
        let speed: CGFloat = 4.5 * sizeScale
        // Births per point of seam — constant density, so total births track length through
        // the generator count; tapered toward the two ends below.
        let density: CGFloat = 0.75

        // Each sparkle takes a random color between the full seam color and white (see below),
        // plus a slight independent hue wander (`hueJitter`) so the shimmer isn't monochrome.
        let s = color.usingColorSpace(.sRGB) ?? color
        let midR = (s.redComponent + 1) / 2, midG = (s.greenComponent + 1) / 2, midB = (s.blueComponent + 1) / 2
        let hueJitter: CGFloat = 0.14   // extra per-channel spread → subtle hue variation

        // Lay the segments end-to-end along the seam. Each emitter layer is given a real
        // `frame` in the seam's (already view-space) coordinates — same as the glow layers —
        // so its geometry inherits the host's y-up mapping. `emitterPosition` is then a plain
        // *local* center within that frame (no y-flip): the seam logic already ran before the
        // transform and arrived here correctly, so we must not re-flip it.
        let lo = vertical ? rect.minY : rect.minX
        let segLen = long / CGFloat(count)
        // Gentle falloff toward the two ends of the seam: full density mid-bar, fading over a
        // `ramp` band at each end (never fully dark, so short bars still shimmer).
        let ramp = max(segLen, long * 0.18)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, layer) in segs.enumerated() {
            let center = lo + segLen * (CGFloat(i) + 0.5)
            // The segment's frame: `segLen` along the seam, thin across it, centered on the
            // seam line (`lineCoord`) with the backset already folded in.
            let frame = vertical
                ? NSRect(x: lineCoord - 1, y: center - segLen / 2, width: 2, height: segLen)
                : NSRect(x: center - segLen / 2, y: lineCoord - 1, width: segLen, height: 2)
            layer.transform = CATransform3DIdentity
            layer.frame = frame
            layer.emitterPosition = CGPoint(x: frame.width / 2, y: frame.height / 2)  // local center
            // Thin box: `segLen` along the seam, a hair (2) deep so `.volume` seeds cleanly.
            layer.emitterSize = vertical ? CGSize(width: 2, height: segLen) : CGSize(width: segLen, height: 2)

            // Taper: births scale with this segment's distance to the nearer end of the bar.
            let distToEnd = min(center - lo, lo + long - center)
            let taper = max(0.15, min(1, distToEnd / ramp))
            let segBirth = Float(density * segLen * taper)

            // Two populations share the same kinematics (speed, inward fan, tapered births):
            //  • the main shimmer — a random color between the full seam color and white, with
            //    a slight independent hue wander;
            //  • a sparse scatter of *tinier, yellow-range* sparks that show up regardless of
            //    the seam color, for a bit of warm glint.
            let dot = configuredCell(layer, at: 0, speed: speed, angle: angle, life: travelBoost)
            // CA randomizes each channel symmetrically (base ± range): base at each channel's
            // seam→white midpoint spans exactly [seam, white]; a `hueJitter` floor keeps even
            // near-white channels wiggling independently so the hue drifts too.
            dot.color = NSColor(srgbRed: midR, green: midG, blue: midB, alpha: 0.95).cgColor
            dot.redRange = Float(max(1 - midR, hueJitter))
            dot.greenRange = Float(max(1 - midG, hueJitter))
            dot.blueRange = Float(max(1 - midB, hueJitter))
            dot.birthRate = segBirth
            dot.scale = 0.14 * sizeScale                 // smaller on average
            dot.scaleRange = 0.16 * sizeScale            // wider spread → sizes vary more, twinklier

            let gold = configuredCell(layer, at: 1, speed: speed, angle: angle, life: travelBoost)
            gold.color = NSColor(srgbRed: 1.0, green: 0.86, blue: 0.35, alpha: 0.95).cgColor
            gold.redRange = 0; gold.greenRange = 0.14; gold.blueRange = 0.2   // amber↔pale-gold wander
            gold.birthRate = segBirth * 0.12             // sparse — a rare warm glint
            gold.scale = 0.08 * sizeScale                // tinier than the main shimmer
            gold.scaleRange = 0.05 * sizeScale
            layer.emitterCells = [dot, gold]
        }
        CATransaction.commit()
    }

    /// Fetch/create the emitter cell at index `idx` on `layer` and apply the kinematics
    /// shared by both sparkle populations (contents, inward fan, speed, lifetime, no color
    /// drift). `life` stretches lifetime for a deeper drift at the same speed, with the fade
    /// and shrink rates stretched to match (so a long-lived sparkle doesn't blink out or
    /// vanish to a dot early). The caller sets color/scale/birthRate for its population.
    private func configuredCell(_ layer: CAEmitterLayer, at idx: Int, speed: CGFloat, angle: CGFloat,
                                life: CGFloat) -> CAEmitterCell {
        let cells = layer.emitterCells ?? []
        let cell = idx < cells.count ? cells[idx] : makeCell()
        cell.contents = sprite
        cell.redSpeed = 0; cell.greenSpeed = 0; cell.blueSpeed = 0
        cell.velocity = speed
        cell.velocityRange = speed * 0.5
        cell.emissionLongitude = angle               // global inward direction (y-up frame)
        cell.emissionRange = 0.15                     // tight fan → clearly perpendicular
        cell.lifetime = Float(1.0 * life)
        cell.lifetimeRange = Float(0.9 * life)        // wide spread: lives ~0.1–1.9s (×life)
        cell.alphaSpeed = Float(-0.85 / life)         // fade over the (stretched) life
        cell.scaleSpeed = -0.25 / life                // shrink as they travel, over the same life
        return cell
    }

    /// Finish the pass: retire emitters whose edge no longer exists.
    func commit() {
        for (id, segs) in layers where !seen.contains(id) {
            segs.forEach { $0.removeFromSuperlayer() }
            layers[id] = nil
        }
    }

    /// Remove everything (arranger closing).
    func clear() {
        layers.values.flatMap { $0 }.forEach { $0.removeFromSuperlayer() }
        layers.removeAll()
    }

    /// The `count` segment emitters for `id`, creating/retiring to match — the count follows
    /// the bar's length, so a bar growing under a drag gains generators and a shrinking one
    /// sheds them (the survivors are reused so existing particles keep animating).
    private func segments(id: String, count: Int) -> [CAEmitterLayer] {
        var segs = layers[id] ?? []
        if segs.count > count {
            segs[count...].forEach { $0.removeFromSuperlayer() }
            segs.removeSubrange(count...)
        }
        while segs.count < count { segs.append(makeEmitter()) }
        layers[id] = segs
        return segs
    }

    private func makeEmitter() -> CAEmitterLayer {
        let e = CAEmitterLayer()
        // Every emitter layer defaults to the same RNG seed, so identically-configured
        // segments play *identical* particle streams — the seam reads as a tiled repeat.
        // A random seed per generator de-syncs them.
        e.seed = UInt32.random(in: .min ... .max)
        // A rectangle emitter spreads births uniformly across its `emitterSize` box on both
        // axes (a thin box along the seam), and `emissionLongitude` fires in the unrotated
        // y-up frame — so no layer rotation, and direction is a plain global angle.
        e.emitterShape = .rectangle
        e.emitterMode = .volume
        e.renderMode = .unordered         // distinct sparkles, no additive blow-out
        e.emitterCells = [makeCell()]
        host.addSublayer(e)
        return e
    }

    private func makeCell() -> CAEmitterCell {
        let cell = CAEmitterCell()
        // Lifetime/fade/shrink live in `configuredCell` (they stretch with `travelBoost`);
        // color drift (white → seam color) is per-seam, set in `add`.
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
