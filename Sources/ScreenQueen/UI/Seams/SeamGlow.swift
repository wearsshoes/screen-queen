import QuartzCore

/// The tight, bright seam glow that sits *in front of* the sparkles. The sparkle emitters
/// render on their own layer above the canvas's drawn content, so a glow painted in
/// `draw(_:)` can only ever sit *behind* them — this manager owns a layer above the
/// emitters and paints one gradient sublayer per seam edge, hugging the seam and fading a
/// short way toward the display center (the brighter core; the wide soft bleed behind the
/// sparkles is drawn in the canvas).
///
/// Mirrors `SeamEmitters`' begin/add/commit lifecycle: the canvas recomputes bar geometry
/// every `draw(_:)` and hands us the current edges, and we create/reposition/retire one
/// gradient layer per edge.
@MainActor
final class SeamGlow {

    /// Which way the glow fades (toward the display center) from the seam edge.
    enum Edge { case minX, maxX, minY, maxY }

    private let host: CALayer
    /// Live gradient layers keyed by a stable per-edge id (shared with the emitters).
    private var layers: [String: CAGradientLayer] = [:]
    /// Ids seen during the current begin…commit pass (to retire the rest).
    private var seen: Set<String> = []

    init(host: CALayer) {
        self.host = host
    }

    /// Start a geometry pass (once per `draw(_:)`, before the `add` calls).
    func begin() { seen.removeAll(keepingCapacity: true) }

    /// Register/refresh the front glow for one seam edge. `rect` is the bar; `inward` is the
    /// direction toward the display center (the fade direction). The glow is bright at the
    /// seam (flat, outward) edge and transparent at the inward edge.
    func add(rect: CGRect, inward: Edge, color: CGColor, id: String) {
        seen.insert(id)
        let layer = layers[id] ?? makeLayer(id: id)

        // Geometry updates shouldn't animate (they'd lag the layout).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = rect
        // Gradient start/end points are in the layer's unit space. This layer is hosted in an
        // unflipped NSView, so its unit space is y-up like the view: unit y=0 is the bar's
        // bottom (minY), y=1 the top (maxY). Fade from the seam (outward) edge → inward edge.
        switch inward {
        case .minX: layer.startPoint = CGPoint(x: 1, y: 0.5); layer.endPoint = CGPoint(x: 0, y: 0.5)
        case .maxX: layer.startPoint = CGPoint(x: 0, y: 0.5); layer.endPoint = CGPoint(x: 1, y: 0.5)
        // inward .minY: seam at top (maxY, y=1) → fade toward bottom (minY, y=0).
        case .minY: layer.startPoint = CGPoint(x: 0.5, y: 1); layer.endPoint = CGPoint(x: 0.5, y: 0)
        // inward .maxY: seam at bottom (minY, y=0) → fade toward top (maxY, y=1).
        case .maxY: layer.startPoint = CGPoint(x: 0.5, y: 0); layer.endPoint = CGPoint(x: 0.5, y: 1)
        }
        // Bright core at the seam, quick fade to clear — this is the front highlight, so it
        // stays tight (fully faded by ~60% across the bar).
        layer.colors = [color, color.copy(alpha: 0) ?? color]
        layer.locations = [0, 0.6]
        // Taper the glow toward the two *ends* of the seam via an along-length alpha mask
        // (opaque middle → clear ends), so it fades out gently at the tips instead of stopping
        // square. `along` = the seam's long axis (y for vertical seams, x for horizontal).
        layer.mask = endTaperMask(size: rect.size, alongY: inward == .minX || inward == .maxX)
        CATransaction.commit()
    }

    /// An along-length alpha mask: opaque through the middle, fading to transparent at both
    /// ends of the seam, so the glow tapers gently at its tips. The ramp is point-based
    /// (capped fraction on short bars), so a long seam's tips stay tight and readable
    /// instead of dissolving over a fifth of its length. `alongY` = the seam runs along y
    /// (vertical seam); otherwise along x.
    private func endTaperMask(size: CGSize, alongY: Bool) -> CAGradientLayer {
        let m = CAGradientLayer()
        m.frame = CGRect(origin: .zero, size: size)
        let alongLen = max(alongY ? size.height : size.width, 1)
        let ramp = min(18, alongLen * 0.25) / alongLen
        // White = opaque (glow shows), clear = masked out.
        let solid = CGColor(gray: 1, alpha: 1), clear = CGColor(gray: 1, alpha: 0)
        m.colors = [clear, solid, solid, clear]
        m.locations = [0, NSNumber(value: ramp), NSNumber(value: 1 - ramp), 1]
        if alongY { m.startPoint = CGPoint(x: 0.5, y: 0); m.endPoint = CGPoint(x: 0.5, y: 1) }
        else      { m.startPoint = CGPoint(x: 0, y: 0.5); m.endPoint = CGPoint(x: 1, y: 0.5) }
        return m
    }

    /// Finish the pass: retire glows whose edge no longer exists.
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

    private func makeLayer(id: String) -> CAGradientLayer {
        let g = CAGradientLayer()
        host.addSublayer(g)
        layers[id] = g
        return g
    }
}
