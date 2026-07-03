import SwiftUI

/// The machinery every seam depiction shares — the tile-space bars (Minimap/TileSeams),
/// the on-glass edge bars (Chrome/Glass/EdgeSeams), and the always-on lights
/// (SeamLights): one seam wears one color everywhere, and the two arranger depictions
/// share glow rendering and emitter registration.
///
/// The edge set is computed once (`miniBarEdges`/`edgeBarEdges`, pure); the draw pass
/// paints the behind-glows from it, and `updateSeamEffects()` (refresh path) feeds the
/// same edges to the emitter/glow layers — the draw pass registers nothing.

/// The stage-free half of the engine: seam detection over a *committed* point layout,
/// for consumers reading the real desk rather than the arranger's plane.
enum SeamEngine {
    /// Every seam in a committed layout: pairwise shared edges among the plane
    /// displays (mirrored slaves have no seams of their own).
    static func committedSeams(_ displays: [DisplaySnapshot])
        -> [(a: DisplaySnapshot, b: DisplaySnapshot, seam: SchematicLayout.Seam)] {
        let plane = displays.filter { !$0.isMirrored }
        var seams: [(a: DisplaySnapshot, b: DisplaySnapshot, seam: SchematicLayout.Seam)] = []
        for i in 0..<plane.count {
            for j in (i + 1)..<plane.count {
                guard let s = SchematicLayout.seam(plane[i].bounds, plane[j].bounds) else { continue }
                seams.append((plane[i], plane[j], s))
            }
        }
        return seams
    }
}

/// The app's one seam→color assignment, shared by every consumer so a seam wears the
/// same color everywhere. Feeds the last assignment back into the edge-coloring
/// (`DisplayGraph`, the pure index math), so a surviving seam keeps its color across
/// rebuilds; the colors themselves come from the house palette (`SeamPalette`).
@MainActor
final class SeamColorBook {
    static let shared = SeamColorBook()

    private var last: [DisplayGraph.SeamKey: Int] = [:]

    /// The color for each seam (unordered display pair), stable across calls.
    func colors(for pairs: [(CGDirectDisplayID, CGDirectDisplayID)]) -> [DisplayGraph.SeamKey: NSColor] {
        let indices = DisplayGraph.seamColorIndices(pairs, previous: last)
        last = indices   // only surviving seams (the result drops vanished ones)
        return indices.mapValues { SeamPalette.colors[$0 % SeamPalette.colors.count] }
    }
}

extension ArrangerModel {
    /// Colors keyed by seam (unordered display pair) — via the shared `SeamColorBook` so
    /// the arranger and the always-on seam lights agree. Lives here (not in the
    /// framework-free model file) because NSColor is AppKit vocabulary.
    func seamColors(_ bars: [SeamBar]) -> [DisplayGraph.SeamKey: NSColor] {
        SeamColorBook.shared.colors(for: bars.map { ($0.aID, $0.bID) })
    }
}

extension Stage {

    /// One seam edge: where a bar hugs a seam, which way it rounds/drifts, its color.
    struct SeamEdgeGlow {
        let rect: NSRect
        let inward: RectEdge
        let color: NSColor
    }

    /// The shared end-trim rule for seam bars (mini-map and on-glass): clear the ends
    /// by up to `cap`, capped at a third so a short bar's length stays proportional
    /// to the true overlap.
    func trimmedBarLength(_ full: CGFloat, cap: CGFloat) -> CGFloat {
        max(1.5, full - min(cap, full / 3))
    }

    enum RectEdge { case minX, maxX, minY, maxY }

    // MARK: - Effect layers (refresh path — never from draw)

    /// Register the current seam edges with the sparkle emitters and the front glow.
    /// Layer work, so it lives on the refresh path with the other overlay updates.
    func updateSeamEffects() {
        let rects = currentRects()
        guard let t = drawTransform(rects) else { return }
        let bars = model.currentBars()
        let seamColor = model.seamColors(bars)
        seamEmitters.begin()
        seamGlow.begin()
        for e in minimap.miniBarEdges(bars, t: t, seamColor: seamColor) {
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
        // not the stage painted beneath it.
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
