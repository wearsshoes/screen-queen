import AppKit

/// Rendering: draws the schematic (tiles, labels, reference/edge bars, alignment
/// markers, boxing) from the shared `state` and the view transform.
extension ArrangementCanvas {

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Each per-screen window owns its own dim backdrop.
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()

        let rects = currentRects()
        guard let t = dragTransform ?? transform(rects) else {
            drawCenteredMessage("No displays detected")
            return
        }
        let bars = currentBars()
        if showAlignGhosts { drawAlignGhosts(t: t) }   // under the tiles
        for d in displays where rects[d.id] != nil { drawTile(for: d, in: t.viewRect(rects[d.id]!)) }
        drawReferenceBars(bars, t: t)
        let markers = activeMarkers(rects)
        for d in displays where rects[d.id] != nil { drawAnchors(for: d, in: t.viewRect(rects[d.id]!), active: markers[d.id]) }
        drawEdgeBars(bars)      // full-screen reference bars hugging this screen's real edges
        drawScreenMarkers(activeMarkers(rects))   // alignment notches/arrows at this screen's real edges
        drawFooter("Drag to rearrange · ⌘/arrows select · arrows nudge · ⌘⇧ align · ⌘ ± 0 resolution")
        if let p = draggingMenuBar {
            // The strip follows the cursor; highlight the tile it would land on.
            if let over = display(at: p), !over.isMain, let r = rects[over.id] {
                let vr = t.viewRect(r).insetBy(dx: 1.5, dy: 1.5)
                NSColor.white.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: vr, xRadius: tileCornerRadius, yRadius: tileCornerRadius).fill()
            }
            drawMenuBar(in: NSRect(x: p.x - 40, y: p.y - 8, width: 80, height: 16))
        }
    }

    /// Reference bars at each seam, from the shared `SchematicLayout`: the reference
    /// window shown on each side in the facing color, at its own physical size (which
    /// differs by density — the size jump a window makes crossing the seam).
    private func drawReferenceBars(_ bars: [SeamBar], t: Transform) {
        let thickness: CGFloat = 5, gap: CGFloat = 5   // inset each bar off the seam line
        let trim: CGFloat = 8                          // shorten so ends clear the tile's rounded corners
        for bar in bars {
            let lenA = max(2, bar.physLenInchesA * t.scale - trim)
            let lenB = max(2, bar.physLenInchesB * t.scale - trim)
            if bar.isVertical {
                let cA = t.viewPoint(CGPoint(x: bar.physLine, y: bar.physAlongA))
                let cB = t.viewPoint(CGPoint(x: bar.physLine, y: bar.physAlongB))
                drawBar(NSRect(x: cA.x - thickness - gap, y: cA.y - lenA / 2, width: thickness, height: lenA))
                drawBar(NSRect(x: cB.x + gap, y: cB.y - lenB / 2, width: thickness, height: lenB))
            } else {
                let cA = t.viewPoint(CGPoint(x: bar.physAlongA, y: bar.physLine))
                let cB = t.viewPoint(CGPoint(x: bar.physAlongB, y: bar.physLine))
                drawBar(NSRect(x: cA.x - lenA / 2, y: cA.y - thickness - gap, width: lenA, height: thickness))
                drawBar(NSRect(x: cB.x - lenB / 2, y: cB.y + gap, width: lenB, height: thickness))
            }
        }
    }

    /// Mini-map reference bars are drawn fully white (the on-glass edge bars keep
    /// each display's color).
    private func drawBar(_ rect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    }

    /// Full-screen reference bars hugging *this* screen's real edges (in its own
    /// point coordinates), in the facing display's color — the on-glass depiction of
    /// how big a window is as it crosses the seam. Drawn only on the window that sits
    /// on the participating screen.
    private func drawEdgeBars(_ bars: [SeamBar]) {
        guard let me = centerID else { return }
        let thickness: CGFloat = 9, endMargin: CGFloat = 6
        // On a notched display, keep top-edge bars below the menu-bar/notch area.
        let notch = window?.screen?.safeAreaInsets.top ?? 0
        for bar in bars where bar.aID == me || bar.bID == me {
            let weAreA = (bar.aID == me)
            let facing = colorFor[weAreA ? bar.bID : bar.aID] ?? .systemGray
            let along = weAreA ? bar.localAlongA : bar.localAlongB
            let len = max(0, bar.windowPoints - 2 * endMargin)   // small margin at each end
            let rect: NSRect
            // `inward` is the side facing the screen center (rounded); the opposite,
            // outward side sits flat against the screen edge.
            let inward: RectEdge
            if bar.isVertical {
                let x = weAreA ? bounds.width - thickness : 0    // a = left display
                rect = NSRect(x: x, y: along - len / 2, width: thickness, height: len)
                inward = weAreA ? .minX : .maxX                  // a hugs the right edge → rounds left
            } else {
                let y = weAreA ? bounds.height - thickness : notch
                rect = NSRect(x: along - len / 2, y: y, width: len, height: thickness)
                inward = weAreA ? .minY : .maxY
            }
            facing.setFill()
            dPath(rect, roundedOn: inward).fill()
        }
    }

    private enum RectEdge { case minX, maxX, minY, maxY }

    /// A rounded rect with only the two corners on the `inward` edge rounded (the
    /// outward edge and its corners stay square). `appendArc(from:to:radius:)` rounds
    /// each traversed corner; feeding radius 0 at the outward corners keeps them flat.
    private func dPath(_ r: NSRect, roundedOn inward: RectEdge) -> NSBezierPath {
        let cr = min(r.width, r.height) * 0.45   // corner radius on the inward side
        // Corners in order (bl, br, tr, tl) with the radius to use at each.
        let bl = CGPoint(x: r.minX, y: r.minY), br = CGPoint(x: r.maxX, y: r.minY)
        let tr = CGPoint(x: r.maxX, y: r.maxY), tl = CGPoint(x: r.minX, y: r.maxY)
        func rad(_ c: RectEdge...) -> CGFloat { c.contains(inward) ? cr : 0 }
        // Radius per corner: a corner is rounded iff it lies on the inward edge.
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

    private func drawTile(for display: DisplaySnapshot, in rect: NSRect) {
        let color = colorFor[display.id] ?? .systemGray
        let selected = display.id == selectedID
        let inset = rect.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: tileCornerRadius, yRadius: tileCornerRadius)
        color.withAlphaComponent(selected ? 0.95 : 0.8).setFill(); path.fill()
        // The selected tile is outlined white so it's clear which display a zoom /
        // resolution change will affect.
        (selected ? NSColor.white : color).setStroke()   // selected tile: white outline
        path.lineWidth = selected ? 3 : 1.5; path.stroke()
        drawBoxing(for: display, in: inset, color: color)
        drawLabel(for: display, in: inset)
        drawFingerprint(display, in: inset)
        // The main display carries a menu-bar strip (drag it to another tile to move main).
        if display.isMain, draggingMenuBar == nil { drawMenuBar(in: menuBarRect(inTile: inset)) }
    }

    /// The first 5 chars of the display's EDID-hash fingerprint, faint at the tile
    /// bottom — a quick way to see identical monitors are being told apart. Skipped
    /// for the built-in (no EDID hash).
    private func drawFingerprint(_ display: DisplaySnapshot, in rect: NSRect) {
        guard let hash = display.edidHash else { return }
        let text = String(hash.prefix(5))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.35),
        ]
        let s = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: rect.midX - s.width / 2, y: rect.maxY - s.height - 4),
                                withAttributes: attrs)   // flipped view: maxY is the bottom
    }

    /// If the current (or previewed) mode's aspect ratio doesn't match the panel's
    /// physical shape, the image is letter-/pillar-boxed. Draw the actual image area as
    /// an inset rectangle and hatch the black-bar regions so it's obvious.
    private func drawBoxing(for display: DisplaySnapshot, in tile: NSRect, color: NSColor) {
        // Image aspect from the current or pending pixel resolution.
        let pending = pendingMode?.id == display.id ? pendingMode?.mode : nil
        let imgW = Double(pending?.pixelWidth ?? Int(display.pixelSize.width))
        let imgH = Double(pending?.pixelHeight ?? Int(display.pixelSize.height))
        // Compare the image aspect against the panel's native pixel aspect.
        guard imgW > 0, imgH > 0, let panAspect = nativeAspect(display.id) else { return }
        let imgAspect = imgW / imgH
        guard abs(imgAspect - panAspect) / panAspect > 0.02 else { return }   // fills the panel

        // The image rect: the largest tile-centered rect with the image's aspect.
        var img = tile.insetBy(dx: 2, dy: 2)
        if imgAspect > panAspect {                 // wider than panel → letterbox (bars top/bottom)
            let h = img.width / CGFloat(imgAspect)
            img = NSRect(x: img.minX, y: img.midY - h / 2, width: img.width, height: h)
        } else {                                   // narrower → pillarbox (bars left/right)
            let w = img.height * CGFloat(imgAspect)
            img = NSRect(x: img.midX - w / 2, y: img.minY, width: w, height: img.height)
        }
        // Outline the image area; hatch the boxed (black-bar) regions with diagonal lines.
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let outline = NSBezierPath(rect: img); outline.lineWidth = 1; outline.stroke()
        hatch(tile.insetBy(dx: 2, dy: 2), excluding: img, color: NSColor.black.withAlphaComponent(0.3))
    }

    /// Native pixel aspect for `id`, cached in `nativeAspectCache`.
    func nativeAspect(_ id: CGDirectDisplayID) -> Double? {
        if let cached = nativeAspectCache[id] { return cached }
        let a = ModeCatalog.nativeAspect(for: id)
        nativeAspectCache[id] = a
        return a
    }

    /// Fill the region of `rect` outside `hole` with faint diagonal hatch lines.
    private func hatch(_ rect: NSRect, excluding hole: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(rect: rect)
        clip.append(NSBezierPath(rect: hole).reversed)   // even-odd hole
        clip.addClip()
        color.setStroke()
        let path = NSBezierPath(); path.lineWidth = 1
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY)); path.line(to: CGPoint(x: x + rect.height, y: rect.maxY))
            x += 6
        }
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The menu-bar strip across the top of a tile (flipped view: min-y is the top).
    func menuBarRect(inTile tile: NSRect) -> NSRect {
        return NSRect(x: tile.minX, y: tile.minY, width: tile.width, height: min(18, tile.height * 0.2))
    }

    private func drawMenuBar(in rect: NSRect) {
        let clip = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        NSColor.white.withAlphaComponent(0.6).setFill(); clip.fill()
    }

    private func drawLabel(for display: DisplaySnapshot, in rect: NSRect) {
        let sz = pointSize(display)
        let pending = pendingMode?.id == display.id ? pendingMode?.mode : nil
        let pixelW = pending?.pixelWidth ?? Int(display.pixelSize.width)

        // Effective PPI (points per physical inch, from the live/previewed point size).
        let effPPI = display.diagonalInches > 0 && sz.width > 0
            ? Double(sz.width) / (Double(display.physicalSizeMM.width) / 25.4) : nil

        // Text size proportional to how big it appears on the screen: higher PPI →
        // physically smaller → smaller tile text. Normalized around ~110 ppi, +25%.
        let fontScale = CGFloat(max(0.5, min(4.0, 110.0 / (effPPI ?? 110)))) * 1.25
        func f(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
            let base = bold ? NSFont.boldSystemFont(ofSize: size * fontScale) : .systemFont(ofSize: size * fontScale)
            return italic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
        }

        var lines: [(String, NSFont, NSColor)] = []
        lines.append((display.name, f(16, bold: true), .labelColor))

        // Resolution "W×H" (points) with HiDPI tagged on; italic while a zoom mode is
        // uncommitted.
        let hidpi = pixelW > Int(sz.width) ? " HiDPI" : ""
        lines.append(("\(Int(sz.width))×\(Int(sz.height))" + hidpi, f(13, italic: pending != nil), .labelColor))

        // Diagonal inches then effective PPI.
        let diag = display.diagonalInches > 0 ? String(format: "%.0f″ · ", display.diagonalInches) : ""
        if let effPPI {
            lines.append((diag + String(format: "%.0f ppi", effPPI), f(13), .secondaryLabelColor))
        } else {
            lines.append((diag + "calibrate?", f(13), .secondaryLabelColor))
        }

        // Center the block vertically and each line horizontally in the tile.
        let attrsFor: (NSFont) -> [NSAttributedString.Key: Any] = { [.font: $0] }
        let sizes = lines.map { ($0.0 as NSString).size(withAttributes: attrsFor($0.1)) }
        let gap: CGFloat = 3
        let total = sizes.reduce(0) { $0 + $1.height } + gap * CGFloat(lines.count - 1)
        var y = rect.midY - total / 2
        for (i, (text, font, color)) in lines.enumerated() {
            let s = sizes[i]
            guard s.width <= rect.width - 8 else { y += s.height + gap; continue }
            (text as NSString).draw(at: CGPoint(x: rect.midX - s.width / 2, y: y),
                                    withAttributes: [.font: font, .foregroundColor: color])
            y += s.height + gap
        }
    }

    /// The eight perimeter anchor positions (corners + edge midpoints).
    private enum AnchorPos: CaseIterable {
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
    /// at each other.
    private func drawAnchors(for display: DisplaySnapshot, in rect: NSRect, active: (pos: AnchorPos, dir: CGVector)?) {
        let tile = rect.insetBy(dx: 1.5, dy: 1.5), r = tileCornerRadius
        // Markers sit inside the reference bars / menu strip (corners move diagonally).
        let marginTile = tile.insetBy(dx: 24, dy: 24)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: tile, xRadius: r, yRadius: r).setClip()
        for pos in AnchorPos.allCases where active?.pos != pos {
            drawNotch(at: pos.point(in: marginTile), dir: pos.inward)
        }
        NSGraphicsContext.restoreGraphicsState()
        if let active { drawArrow(at: active.pos.point(in: marginTile), dir: active.dir) }
    }

    /// The active alignment marker for this screen, drawn large at its real edges (in
    /// its own point coords) — the on-glass counterpart of the mini-map notches.
    private func drawScreenMarkers(_ markers: [CGDirectDisplayID: (pos: AnchorPos, dir: CGVector)]) {
        guard let me = centerID, let active = markers[me] else { return }
        let notch = window?.screen?.safeAreaInsets.top ?? 0   // keep clear of the notch on top
        let area = NSRect(x: bounds.minX + 40, y: bounds.minY + 40 + notch,
                          width: bounds.width - 80, height: bounds.height - 80 - notch)
        drawArrow(at: active.pos.point(in: area), dir: active.dir, scale: 3)
    }

    /// Grey ghosts of where each valid ⌘⇧ arrow would move the selected tile, with a
    /// direction arrow. Drawn under the real tiles. The arrow sits at the ghost's
    /// center, or the center of its overlap with the current tile, or (if that overlap
    /// is too small) just outside the current tile in the move direction.
    private func drawAlignGhosts(t: Transform) {
        guard let selID = selectedID, let cur = plane[selID] else { return }
        let curView = t.viewRect(cur)
        for (dir, rect) in alignGhosts() {
            let g = t.viewRect(rect)
            let box = g.insetBy(dx: 1.5, dy: 1.5)
            NSColor.gray.withAlphaComponent(0.35).setFill()
            let path = NSBezierPath(roundedRect: box, xRadius: tileCornerRadius, yRadius: tileCornerRadius)
            path.fill()
            NSColor.white.withAlphaComponent(0.5).setStroke()   // lighter outline
            path.lineWidth = 1; path.stroke()

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
            let travel: CGVector   // flipped view: up = -y
            switch dir {
            case .left:  travel = CGVector(dx: -1, dy: 0)
            case .right: travel = CGVector(dx: 1, dy: 0)
            case .up:    travel = CGVector(dx: 0, dy: -1)
            case .down:  travel = CGVector(dx: 0, dy: 1)
            }
            drawDirectionArrow(centeredAt: at, pointing: travel, length: 34)
        }
    }

    /// A clean "→"-style arrow (line shaft + open chevron head) pointing along `dir`,
    /// centered at `p`.
    private func drawDirectionArrow(centeredAt p: CGPoint, pointing dir: CGVector, length: CGFloat) {
        let n = unit(dir)
        let tail = CGPoint(x: p.x - n.dx * length / 2, y: p.y - n.dy * length / 2)
        let tip  = CGPoint(x: p.x + n.dx * length / 2, y: p.y + n.dy * length / 2)
        let perp = CGVector(dx: -n.dy, dy: n.dx)
        let head: CGFloat = 9
        let path = NSBezierPath()
        path.move(to: tail); path.line(to: tip)                                  // shaft
        path.move(to: CGPoint(x: tip.x - n.dx * head + perp.dx * head, y: tip.y - n.dy * head + perp.dy * head))
        path.line(to: tip)                                                       // chevron
        path.line(to: CGPoint(x: tip.x - n.dx * head - perp.dx * head, y: tip.y - n.dy * head - perp.dy * head))
        path.lineWidth = 3; path.lineCapStyle = .round; path.lineJoinStyle = .round
        NSColor.white.setStroke(); path.stroke()
    }

    /// Markers for the active alignment, read from the stored anchor pair; the
    /// facing side comes from the rendered rects.
    private func activeMarkers(_ rects: [CGDirectDisplayID: CGRect]) -> [CGDirectDisplayID: (pos: AnchorPos, dir: CGVector)] {
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

    private func drawNotch(at p: CGPoint, dir: CGVector) {
        let n = unit(dir), len: CGFloat = 4
        let path = NSBezierPath()
        path.move(to: p); path.line(to: CGPoint(x: p.x + n.dx * len, y: p.y + n.dy * len))
        path.lineWidth = 2; path.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke(); path.stroke()
    }

    private func drawArrow(at p: CGPoint, dir: CGVector, scale: CGFloat = 1) {
        let inward = unit(dir), out = CGVector(dx: -inward.dx, dy: -inward.dy)
        let len: CGFloat = 7 * scale, half: CGFloat = 4 * scale
        let perp = CGVector(dx: -out.dy, dy: out.dx)
        let apex = CGPoint(x: p.x + out.dx * len, y: p.y + out.dy * len)
        let b1 = CGPoint(x: p.x + perp.dx * half, y: p.y + perp.dy * half)
        let b2 = CGPoint(x: p.x - perp.dx * half, y: p.y - perp.dy * half)
        let tri = NSBezierPath(); tri.move(to: apex); tri.line(to: b1); tri.line(to: b2); tri.close()
        NSColor.white.setFill(); tri.fill()
    }

    private func unit(_ v: CGVector) -> CGVector {
        let len = max(hypot(v.dx, v.dy), 0.001)
        return CGVector(dx: v.dx / len, dy: v.dy / len)
    }

    private func drawFooter(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 8), withAttributes: attrs)
    }

    private func drawCenteredMessage(_ message: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor]
        let size = (message as NSString).size(withAttributes: attrs)
        (message as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
