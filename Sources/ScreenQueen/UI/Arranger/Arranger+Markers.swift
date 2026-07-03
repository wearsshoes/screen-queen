import SwiftUI

/// Alignment feedback: the eight per-tile anchor notches, the paired arrows for the
/// active alignment (map and on-glass), and the ⌘⇧ align-destination ghosts.
extension Arranger {

    /// The eight perimeter anchor positions (corners + edge midpoints).
    enum AnchorPos: CaseIterable {
        case topLeft, topMid, topRight, leftMid, rightMid, bottomLeft, bottomMid, bottomRight
        func point(in r: NSRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: r.minX, y: r.minY)
            case .topMid: return CGPoint(x: r.midX, y: r.minY)
            case .topRight: return CGPoint(x: r.maxX, y: r.minY)
            case .leftMid: return CGPoint(x: r.minX, y: r.midY)
            case .rightMid: return CGPoint(x: r.maxX, y: r.midY)
            case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
            case .bottomMid: return CGPoint(x: r.midX, y: r.maxY)
            case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
            }
        }
        // Unit vector from the anchor toward the tile center (y-down: down = +y).
        var inward: CGVector {
            switch self {
            case .topLeft: return CGVector(dx: 1, dy: 1)
            case .topMid: return CGVector(dx: 0, dy: 1)
            case .topRight: return CGVector(dx: -1, dy: 1)
            case .leftMid: return CGVector(dx: 1, dy: 0)
            case .rightMid: return CGVector(dx: -1, dy: 0)
            case .bottomLeft: return CGVector(dx: 1, dy: -1)
            case .bottomMid: return CGVector(dx: 0, dy: -1)
            case .bottomRight: return CGVector(dx: -1, dy: -1)
            }
        }
    }

    /// Eight notch markers per tile; the two aligned anchors become arrows pointing
    /// at each other. Native GraphicsContext, one y-down space.
    func drawAnchors(_ ctx: GraphicsContext, for display: DisplaySnapshot, in rect: NSRect,
                     active: (pos: AnchorPos, dir: CGVector)?) {
        let tile = rect.insetBy(dx: 1.5, dy: 1.5), r = tileCornerRadius
        // Markers sit inside the reference bars / menu strip (corners move diagonally).
        let marginTile = tile.insetBy(dx: 24, dy: 24)
        var clipped = ctx
        clipped.clip(to: Path(roundedRect: tile, cornerRadius: r))
        for pos in AnchorPos.allCases where active?.pos != pos {
            drawNotch(clipped, at: pos.point(in: marginTile), dir: pos.inward)
        }
        if let active { drawArrow(ctx, at: active.pos.point(in: marginTile), dir: active.dir) }
    }

    /// The active alignment marker for this screen, drawn large at its real edges (in
    /// its own point coords) — the on-glass counterpart of the mini-map notches.
    func drawScreenMarkers(_ ctx: GraphicsContext, _ markers: [CGDirectDisplayID: (pos: AnchorPos, dir: CGVector)]) {
        guard let me = centerID, let active = markers[me] else { return }
        let notch = window?.screen?.safeAreaInsets.top ?? 0   // keep clear of the notch on top
        let area = NSRect(x: bounds.minX + 40, y: bounds.minY + 40 + notch,
                          width: bounds.width - 80, height: bounds.height - 80 - notch)
        drawArrow(ctx, at: active.pos.point(in: area), dir: active.dir, scale: 3)
    }

    /// Grey ghosts of where each valid ⌘⇧ arrow would move the selected tile, with a
    /// direction arrow. Drawn under the real tiles. The arrow sits at the ghost's
    /// center, or the center of its overlap with the current tile, or (if that overlap
    /// is too small) just outside the current tile in the move direction.
    func drawAlignGhosts(_ ctx: GraphicsContext, t: Transform) {
        guard let selID = selectedID, let cur = plane[selID] else { return }
        let curView = t.viewRect(cur)
        for (dir, rect) in alignGhosts() {
            let g = t.viewRect(rect)
            let box = Path(roundedRect: g.insetBy(dx: 1.5, dy: 1.5), cornerRadius: tileCornerRadius)
            ctx.fill(box, with: .color(Color(white: 0.5).opacity(0.35)))
            ctx.stroke(box, with: .color(.white.opacity(0.5)), lineWidth: 1)   // lighter outline

            // The overlap is covered by the current tile (drawn on top), so aim the
            // arrow at the ghost's *exposed* strip (ghost minus the current tile),
            // biased toward the ghost. If that strip is too thin, nudge just outside.
            let overlap = g.intersection(curView)
            let at: CGPoint
            if overlap.isNull || overlap.width <= 0 || overlap.height <= 0 {
                at = CGPoint(x: g.midX, y: g.midY)               // no overlap → ghost center
            } else {
                let exposedX = max(g.maxX - curView.maxX, 0) >= max(curView.minX - g.minX, 0)
                    ? (g.maxX + curView.maxX) / 2 : (g.minX + curView.minX) / 2
                let exposedY = max(g.maxY - curView.maxY, 0) >= max(curView.minY - g.minY, 0)
                    ? (g.maxY + curView.maxY) / 2 : (g.minY + curView.minY) / 2
                // Move along whichever axis the ghost is actually offset.
                if abs(g.midX - curView.midX) >= abs(g.midY - curView.midY) {
                    at = CGPoint(x: exposedX, y: g.midY)
                } else {
                    at = CGPoint(x: g.midX, y: exposedY)
                }
            }
            let travel: CGVector
            switch dir {
            case .left:  travel = CGVector(dx: -1, dy: 0)
            case .right: travel = CGVector(dx: 1, dy: 0)
            case .up:    travel = CGVector(dx: 0, dy: -1)
            case .down:  travel = CGVector(dx: 0, dy: 1)
            }
            drawDirectionArrow(ctx, centeredAt: at, pointing: travel, length: 34)
        }
    }

    /// A clean "→"-style arrow (line shaft + open chevron head) pointing along `dir`,
    /// centered at `p`.
    private func drawDirectionArrow(_ ctx: GraphicsContext, centeredAt p: CGPoint,
                                    pointing dir: CGVector, length: CGFloat) {
        let n = unit(dir)
        let tail = CGPoint(x: p.x - n.dx * length / 2, y: p.y - n.dy * length / 2)
        let tip  = CGPoint(x: p.x + n.dx * length / 2, y: p.y + n.dy * length / 2)
        let perp = CGVector(dx: -n.dy, dy: n.dx)
        let head: CGFloat = 9
        var path = Path()
        path.move(to: tail); path.addLine(to: tip)                               // shaft
        path.move(to: CGPoint(x: tip.x - n.dx * head + perp.dx * head, y: tip.y - n.dy * head + perp.dy * head))
        path.addLine(to: tip)                                                    // chevron
        path.addLine(to: CGPoint(x: tip.x - n.dx * head - perp.dx * head, y: tip.y - n.dy * head - perp.dy * head))
        ctx.stroke(path, with: .color(.white),
                   style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }

    /// Markers for the active alignment, read from the stored anchor pair; the
    /// facing side comes from the rendered rects.
    func activeMarkers(_ rects: [CGDirectDisplayID: CGRect]) -> [CGDirectDisplayID: (pos: AnchorPos, dir: CGVector)] {
        guard let selID = selectedID, let sR = rects[selID] else { return [:] }
        if let a = activeV, let oR = rects[a.otherID] {
            let selLeft = sR.midX < oR.midX
            let sp = vPos(facingRight: selLeft, level: a.selfA), op = vPos(facingRight: !selLeft, level: a.otherA)
            return [selID: (sp, dirV(sp, corner: a.selfA != .center, partner: a.otherA)),
                    a.otherID: (op, dirV(op, corner: a.otherA != .center, partner: a.selfA))]
        }
        if let a = activeH, let oR = rects[a.otherID] {
            let selAbove = sR.midY < oR.midY
            let sp = hPos(facingBelow: selAbove, level: a.selfA), op = hPos(facingBelow: !selAbove, level: a.otherA)
            return [selID: (sp, dirH(sp, corner: a.selfA != .center, partner: a.otherA)),
                    a.otherID: (op, dirH(op, corner: a.otherA != .center, partner: a.selfA))]
        }
        return [:]
    }

    private func vPos(facingRight: Bool, level: VAnchor) -> AnchorPos {
        switch (facingRight, level) {
        case (true, .top): return .topRight
        case (true, .center): return .rightMid
        case (true, .bottom): return .bottomRight
        case (false, .top): return .topLeft
        case (false, .center): return .leftMid
        case (false, .bottom): return .bottomLeft
        }
    }
    private func hPos(facingBelow: Bool, level: HAnchor) -> AnchorPos {
        switch (facingBelow, level) {
        case (true, .left): return .bottomLeft
        case (true, .center): return .bottomMid
        case (true, .right): return .bottomRight
        case (false, .left): return .topLeft
        case (false, .center): return .topMid
        case (false, .right): return .topRight
        }
    }
    private func dirV(_ pos: AnchorPos, corner: Bool, partner: VAnchor) -> CGVector {
        if corner { return pos.inward }
        guard partner != .center else { return pos.inward }
        return CGVector(dx: pos.inward.dx, dy: partner == .top ? -1 : 1)
    }
    private func dirH(_ pos: AnchorPos, corner: Bool, partner: HAnchor) -> CGVector {
        if corner { return pos.inward }
        guard partner != .center else { return pos.inward }
        return CGVector(dx: partner == .left ? -1 : 1, dy: pos.inward.dy)
    }

    private func drawNotch(_ ctx: GraphicsContext, at p: CGPoint, dir: CGVector) {
        let n = unit(dir), len: CGFloat = 4
        var path = Path()
        path.move(to: p); path.addLine(to: CGPoint(x: p.x + n.dx * len, y: p.y + n.dy * len))
        ctx.stroke(path, with: .color(.white.opacity(0.9)),
                   style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func drawArrow(_ ctx: GraphicsContext, at p: CGPoint, dir: CGVector, scale: CGFloat = 1) {
        let inward = unit(dir), out = CGVector(dx: -inward.dx, dy: -inward.dy)
        let len: CGFloat = 7 * scale, half: CGFloat = 4 * scale
        let perp = CGVector(dx: -out.dy, dy: out.dx)
        let apex = CGPoint(x: p.x + out.dx * len, y: p.y + out.dy * len)
        let b1 = CGPoint(x: p.x + perp.dx * half, y: p.y + perp.dy * half)
        let b2 = CGPoint(x: p.x - perp.dx * half, y: p.y - perp.dy * half)
        var tri = Path()
        tri.move(to: apex); tri.addLine(to: b1); tri.addLine(to: b2); tri.closeSubpath()
        ctx.fill(tri, with: .color(.white))
    }

    private func unit(_ v: CGVector) -> CGVector {
        let len = max(hypot(v.dx, v.dy), 0.001)
        return CGVector(dx: v.dx / len, dy: v.dy / len)
    }
}
