import SwiftUI

/// The seam system: mini-map reference bars and full-screen edge bars, with their
/// shared glow / D-path / emitter plumbing. One seam's two depictions share color,
/// glow rendering, and emitter registration, so they live in one file even though
/// they straddle two coordinate spaces (map vs. on-glass).
///
/// The edge set is computed once (`miniBarEdges`/`edgeBarEdges`, pure); `draw(_:)`
/// paints the behind-glows from it, and `updateSeamEffects()` (refresh path) feeds the
/// same edges to the emitter/glow layers — the draw pass registers nothing.
extension Arranger {

    /// One seam edge: where a bar hugs a seam, which way it rounds/drifts, its color.
    struct SeamEdgeGlow {
        let rect: NSRect
        let inward: RectEdge
        let color: NSColor
    }

    enum RectEdge { case minX, maxX, minY, maxY }

    // MARK: - Edge geometry (pure)

    /// The mini-map bars: two per seam (one each side), D-shaped, flush to the seam,
    /// rounding toward the owning display's center — the reference window shown on each
    /// side at its own physical size (the size jump a window makes crossing the seam).
    func miniBarEdges(_ bars: [SeamBar], t: Transform,
                      seamColor: [DisplayGraph.SeamKey: NSColor]) -> [SeamEdgeGlow] {
        let thickness: CGFloat = 5, gap: CGFloat = 2
        // Trim the ends clear of the rounded corners, capped at 1/3 so a short bar's
        // length stays proportional to the true overlap.
        func barLen(_ inches: CGFloat) -> CGFloat {
            let full = inches * t.scale
            return max(1.5, full - min(8, full / 3))
        }
        var edges: [SeamEdgeGlow] = []
        for bar in bars {
            let color = seamColor[DisplayGraph.SeamKey(bar.aID, bar.bID)] ?? .systemGray
            let lenA = barLen(bar.physLenInchesA)
            let lenB = barLen(bar.physLenInchesB)
            if bar.isVertical {
                let cA = t.viewPoint(CGPoint(x: bar.physLine, y: bar.physAlongA))
                let cB = t.viewPoint(CGPoint(x: bar.physLine, y: bar.physAlongB))
                // a = left display: its bar hugs the seam and rounds toward its center.
                edges.append(SeamEdgeGlow(rect: NSRect(x: cA.x - gap - thickness, y: cA.y - lenA / 2, width: thickness, height: lenA), inward: .minX, color: color))
                edges.append(SeamEdgeGlow(rect: NSRect(x: cB.x + gap, y: cB.y - lenB / 2, width: thickness, height: lenB), inward: .maxX, color: color))
            } else {
                let cA = t.viewPoint(CGPoint(x: bar.physAlongA, y: bar.physLine))
                let cB = t.viewPoint(CGPoint(x: bar.physAlongB, y: bar.physLine))
                // a = top display: its bar sits above the seam and rounds toward its center.
                edges.append(SeamEdgeGlow(rect: NSRect(x: cA.x - lenA / 2, y: cA.y - gap - thickness, width: lenA, height: thickness), inward: .minY, color: color))
                edges.append(SeamEdgeGlow(rect: NSRect(x: cB.x - lenB / 2, y: cB.y + gap, width: lenB, height: thickness), inward: .maxY, color: color))
            }
        }
        return edges
    }

    /// The full-screen bars hugging *this* screen's real edges — the on-glass depiction
    /// of a window's size jump crossing the seam.
    func edgeBarEdges(_ bars: [SeamBar],
                      seamColor: [DisplayGraph.SeamKey: NSColor]) -> [SeamEdgeGlow] {
        guard let me = centerID else { return [] }
        // Constant *physical* thickness: convert inches → points via this screen's density.
        let thicknessInches: CGFloat = 0.08
        let ppi = displays.first { $0.id == me }?.pointsPerInch
        let thickness: CGFloat = ppi.map { thicknessInches * CGFloat($0) } ?? 9
        // Bar offsets/lengths are in *previewed* point space but drawn against the real
        // window bounds — scale them across, or spacing drifts during a zoom preview.
        let previewed = displays.first { $0.id == me }.map { pointSize($0) }
        var edges: [SeamEdgeGlow] = []
        for bar in bars where bar.aID == me || bar.bID == me {
            let weAreA = (bar.aID == me)
            let facing = seamColor[DisplayGraph.SeamKey(bar.aID, bar.bID)] ?? .systemGray
            let axisPreview = bar.isVertical ? (previewed?.height ?? bounds.height)
                                             : (previewed?.width ?? bounds.width)
            let axisReal = bar.isVertical ? bounds.height : bounds.width
            let s = axisPreview > 0 ? axisReal / axisPreview : 1
            let along = (weAreA ? bar.localAlongA : bar.localAlongB) * s
            // End margin capped so a short crossing region shrinks proportionally.
            let len = max(1.5, bar.windowPoints * s - min(12, bar.windowPoints * s / 3))
            let rect: NSRect
            // `inward` = the side facing the screen center (rounded); outward sits flat.
            let inward: RectEdge
            if bar.isVertical {
                let x = weAreA ? bounds.width - thickness : 0    // a = left display
                // `along` is y-down from the screen top, same as the view.
                rect = NSRect(x: x, y: along - len / 2, width: thickness, height: len)
                inward = weAreA ? .minX : .maxX
            } else {
                let y = weAreA ? bounds.height - thickness : 0   // a = above the seam
                rect = NSRect(x: along - len / 2, y: y, width: len, height: thickness)
                inward = weAreA ? .minY : .maxY
            }
            edges.append(SeamEdgeGlow(rect: rect, inward: inward, color: facing))
        }
        return edges
    }

    // MARK: - Effect layers (refresh path — never from draw)

    /// Register the current seam edges with the sparkle emitters and the front glow.
    /// Layer work, so it lives on the refresh path with the other overlay updates.
    func updateSeamEffects() {
        let rects = currentRects()
        guard let t = drawTransform(rects) else { return }
        let bars = currentBars()
        let seamColor = seamColors(bars)
        seamEmitters.begin()
        seamGlow.begin()
        for e in miniBarEdges(bars, t: t, seamColor: seamColor) {
            let eid = barID(e.rect, e.inward)
            seamEmitters.add(edgeOf: e.rect, direction: particleDirection(e.inward), color: e.color.cgColor,
                             id: "mini-\(eid)", sizeScale: screenDensityScale)
            seamGlow.add(rect: e.rect, inward: overlayEdge(e.inward), color: e.color.cgColor, id: "mini-\(eid)")
        }
        for e in edgeBarEdges(bars, seamColor: seamColor) {
            let eid = barID(e.rect, e.inward)
            // Full-screen scale → larger particles, deeper drift than the mini-map bars.
            seamEmitters.add(edgeOf: e.rect, direction: particleDirection(e.inward), color: e.color.cgColor,
                             id: "edge-\(eid)", sizeScale: 2 * screenDensityScale, travelBoost: 3)
            seamGlow.add(rect: e.rect, inward: overlayEdge(e.inward), color: e.color.cgColor, id: "edge-\(eid)")
        }
        seamEmitters.commit()
        seamGlow.commit()
    }

    /// This screen's density relative to the 109 pt/in panels the sparkle look was tuned
    /// on — keeps the shimmer the same *physical* size on every screen.
    private var screenDensityScale: CGFloat {
        let ppi = displays.first { $0.id == centerID }?.pointsPerInch
        return CGFloat(ppi ?? 109) / 109
    }

    /// Map a drawing `RectEdge` to the overlay glow's inward direction.
    private func overlayEdge(_ inward: RectEdge) -> SeamGlow.Edge {
        switch inward {
        case .minX: return .minX
        case .maxX: return .maxX
        case .minY: return .minY
        case .maxY: return .maxY
        }
    }

    /// The direction particles drift: toward the display center = the `inward` edge.
    /// `Direction` is in the emitter's layer space, which rides the flipped view — a
    /// `minY` edge and layer `.down` both mean "+y toward the seam", so the mapping is
    /// flip-invariant.
    private func particleDirection(_ inward: RectEdge) -> SeamEmitters.Direction {
        switch inward {
        case .minX: return .left
        case .maxX: return .right
        case .minY: return .down
        case .maxY: return .up
        }
    }

    /// A stable per-edge id (quantized so sub-pixel jitter doesn't reseed the emitter).
    private func barID(_ r: NSRect, _ inward: RectEdge) -> String {
        "\(Int(r.minX / 3))-\(Int(r.minY / 3))-\(inward)"
    }

    // MARK: - Drawing (paints from the same edges; registers nothing)

    /// The wide, soft glow behind the sparkles: opaque at the seam edge, fading to clear
    /// ~2× the bar depth into the tile, clipped to a D-shape extended to that reach.
    func drawBehindGlow(_ ctx: GraphicsContext, _ e: SeamEdgeGlow) {
        drawBehindGlow(ctx, e.rect, roundedOn: e.inward, color: e.color)
    }

    private func drawBehindGlow(_ ctx: GraphicsContext, _ rect: NSRect, roundedOn inward: RectEdge, color: NSColor) {
        let depth = (inward == .minX || inward == .maxX) ? rect.width : rect.height
        let reach = depth * behindGlowReach
        // Grow the rect inward so its inward edge lands at the glow's end.
        let ext: NSRect
        switch inward {
        case .minX: ext = NSRect(x: rect.maxX - reach, y: rect.minY, width: reach, height: rect.height)
        case .maxX: ext = NSRect(x: rect.minX, y: rect.minY, width: reach, height: rect.height)
        case .minY: ext = NSRect(x: rect.minX, y: rect.maxY - reach, width: rect.width, height: reach)
        case .maxY: ext = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: reach)
        }
        let clipShape = Path(dPath(ext, roundedOn: inward).cgPath)

        // Gradient from the seam edge → the extended inward edge: opaque → clear.
        let (start, end): (CGPoint, CGPoint)
        switch inward {
        case .minX: start = CGPoint(x: ext.maxX, y: ext.midY); end = CGPoint(x: ext.minX, y: ext.midY)
        case .maxX: start = CGPoint(x: ext.minX, y: ext.midY); end = CGPoint(x: ext.maxX, y: ext.midY)
        case .minY: start = CGPoint(x: ext.midX, y: ext.maxY); end = CGPoint(x: ext.midX, y: ext.minY)
        case .maxY: start = CGPoint(x: ext.midX, y: ext.minY); end = CGPoint(x: ext.midX, y: ext.maxY)
        }
        // Own layer, so the destination-out end feathers below erase only the glow,
        // not the canvas painted beneath it.
        ctx.drawLayer { layer in
            layer.clip(to: clipShape)
            layer.fill(Path(ext), with: .linearGradient(
                Gradient(colors: [Color(nsColor: color).opacity(0.7), Color(nsColor: color).opacity(0)]),
                startPoint: start, endPoint: end))

            let vertical = inward == .minX || inward == .maxX
            let alongLen = vertical ? ext.height : ext.width
            let ramp = min(22, alongLen * 0.3)
            guard ramp > 1 else { return }
            layer.blendMode = .destinationOut
            let fade = Gradient(colors: [.black, .black.opacity(0)])
            func feather(_ strip: NSRect, from a: CGPoint, to b: CGPoint) {
                layer.fill(Path(strip), with: .linearGradient(fade, startPoint: a, endPoint: b))
            }
            if vertical {
                feather(NSRect(x: ext.minX, y: ext.minY, width: ext.width, height: ramp),
                        from: CGPoint(x: ext.midX, y: ext.minY), to: CGPoint(x: ext.midX, y: ext.minY + ramp))
                feather(NSRect(x: ext.minX, y: ext.maxY - ramp, width: ext.width, height: ramp),
                        from: CGPoint(x: ext.midX, y: ext.maxY), to: CGPoint(x: ext.midX, y: ext.maxY - ramp))
            } else {
                feather(NSRect(x: ext.minX, y: ext.minY, width: ramp, height: ext.height),
                        from: CGPoint(x: ext.minX, y: ext.midY), to: CGPoint(x: ext.minX + ramp, y: ext.midY))
                feather(NSRect(x: ext.maxX - ramp, y: ext.minY, width: ramp, height: ext.height),
                        from: CGPoint(x: ext.maxX, y: ext.midY), to: CGPoint(x: ext.maxX - ramp, y: ext.midY))
            }
        }
    }

    /// The behind glow reaches this multiple of the bar depth toward the display center.
    private var behindGlowReach: CGFloat { 2 }

    /// A rect with only the two corners on the `inward` edge rounded (radius 0 keeps the
    /// outward corners square).
    private func dPath(_ r: NSRect, roundedOn inward: RectEdge) -> NSBezierPath {
        let cr = min(r.width, r.height) * 0.45
        let bl = CGPoint(x: r.minX, y: r.minY), br = CGPoint(x: r.maxX, y: r.minY)
        let tr = CGPoint(x: r.maxX, y: r.maxY), tl = CGPoint(x: r.minX, y: r.maxY)
        func rad(_ c: RectEdge...) -> CGFloat { c.contains(inward) ? cr : 0 }
        let rBL = rad(.minX, .minY), rBR = rad(.maxX, .minY)
        let rTR = rad(.maxX, .maxY), rTL = rad(.minX, .maxY)

        let p = NSBezierPath()
        p.move(to: CGPoint(x: (bl.x + br.x) / 2, y: bl.y))     // start mid-bottom (away from a corner)
        p.appendArc(from: br, to: tr, radius: rBR)
        p.appendArc(from: tr, to: tl, radius: rTR)
        p.appendArc(from: tl, to: bl, radius: rTL)
        p.appendArc(from: bl, to: br, radius: rBL)
        p.close()
        return p
    }
}
