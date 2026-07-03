import AppKit

/// "What she sees": a small floating panel showing the live reconstructed *point*
/// arrangement — the actual solve `seamBars` uses. Point rects are outlined (red =
/// resolved through an ambiguous >1-preimage inverse); seams draw in their palette
/// color. Draggable; on its own layer above the seam layers.
final class SolvePanel: NSView {

    struct Content {
        var rects: [(id: CGDirectDisplayID, rect: CGRect, ambiguous: Bool)] = []
        var seams: [(a: CGDirectDisplayID, b: CGDirectDisplayID, vertical: Bool, color: NSColor)] = []
    }

    private var content = Content()
    private let titleBarHeight: CGFloat = 16

    /// Ghost mode (inactive display): plate and outlines redraw in pink.
    private var ghost = false

    /// Dragging reports the desired origin here instead of moving the panel itself —
    /// the canvas stores it as a centre-relative inch offset in shared state, and every
    /// canvas repositions on the resulting notify.
    var onMoved: ((CGPoint) -> Void)?

    func update(_ content: Content) {
        self.content = content
        isHidden = content.rects.count < 2   // nothing to say about a solo girl
        needsDisplay = true
    }

    // MARK: - Dragging (grab anywhere on the panel)

    private var titleBar: NSRect {
        NSRect(x: 0, y: bounds.height - titleBarHeight, width: bounds.width, height: titleBarHeight)
    }

    /// The whole panel is the drag handle.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let sup = superview else { return nil }
        return bounds.contains(convert(point, from: sup)) ? self : nil
    }

    private var dragOffset: CGPoint?

    override func mouseDown(with event: NSEvent) {
        guard let sup = superview else { return }
        let p = sup.convert(event.locationInWindow, from: nil)
        dragOffset = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let off = dragOffset, let sup = superview else { return }
        let p = sup.convert(event.locationInWindow, from: nil)
        onMoved?(CGPoint(x: p.x - off.x, y: p.y - off.y))
    }

    override func mouseUp(with event: NSEvent) { dragOffset = nil }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let ink = ghost ? VirtualMouse.pink : NSColor.white
        // Dark rounded plate with a lighter title strip; ghosting tints it toward pink.
        let plate = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        (ghost ? VirtualMouse.pink.blended(withFraction: 0.55, of: .black) ?? .black : .black)
            .withAlphaComponent(0.6).setFill()
        plate.fill()
        NSGraphicsContext.saveGraphicsState()
        plate.addClip()
        ink.withAlphaComponent(0.12).setFill()
        titleBar.fill()
        NSGraphicsContext.restoreGraphicsState()

        let ambiguous = content.rects.contains { $0.ambiguous }
        let title = Copy.solvePanelTitle + (ambiguous ? Copy.solvePanelAmbiguous : "")
        let ta: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 9),
                                                 .foregroundColor: ink.withAlphaComponent(0.8)]
        (title as NSString).draw(at: CGPoint(x: 6, y: bounds.height - titleBarHeight + 3), withAttributes: ta)

        // Fit the point-rect union into the body (point space is y-down; the view is y-up).
        guard content.rects.count >= 2 else { return }
        var uni = content.rects[0].rect
        for e in content.rects.dropFirst() { uni = uni.union(e.rect) }
        guard uni.width > 0, uni.height > 0 else { return }
        let area = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - titleBarHeight)
            .insetBy(dx: 10, dy: 10)
        let s = min(area.width / uni.width, area.height / uni.height)
        func map(_ r: CGRect) -> NSRect {
            let x = area.minX + (r.minX - uni.minX) * s
            let h = r.height * s
            let y = area.maxY - (r.minY - uni.minY) * s - h       // flip: point-top → view-top
            return NSRect(x: x, y: y, width: r.width * s, height: h)
        }

        // Rects + labels first, then the seams stroke *over* the white outlines — the seam is
        // the shared edge, so its color wins there.
        for e in content.rects {
            let vr = map(e.rect)
            (e.ambiguous ? NSColor.systemRed : ink).setStroke()
            let path = NSBezierPath(rect: vr); path.lineWidth = e.ambiguous ? 2 : 1; path.stroke()
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9),
                                                    .foregroundColor: e.ambiguous ? NSColor.systemRed : ink]
            ("\(e.id % 1000)" as NSString).draw(at: CGPoint(x: vr.minX + 2, y: vr.midY - 5), withAttributes: a)
        }
        // The seam pair arrives in arbitrary order, so sort the two view rects geometrically —
        // the line must sit on the shared edge, not wherever (a, b) happened to fall.
        let byID = Dictionary(content.rects.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
        for seam in content.seams {
            guard let ra = byID[seam.a], let rb = byID[seam.b] else { continue }
            seam.color.setStroke()
            let va = map(ra), vb = map(rb)
            let p = NSBezierPath(); p.lineWidth = 3
            if seam.vertical {
                let (l, r) = va.midX <= vb.midX ? (va, vb) : (vb, va)   // left tile by center
                let x = (l.maxX + r.minX) / 2
                p.move(to: CGPoint(x: x, y: max(va.minY, vb.minY))); p.line(to: CGPoint(x: x, y: min(va.maxY, vb.maxY)))
            } else {
                let (t, b) = va.midY >= vb.midY ? (va, vb) : (vb, va)   // upper tile (view y-up)
                let y = (t.minY + b.maxY) / 2
                p.move(to: CGPoint(x: max(va.minX, vb.minX), y: y)); p.line(to: CGPoint(x: min(va.maxX, vb.maxX), y: y))
            }
            p.stroke()
        }
    }
}

extension SolvePanel: GhostTintable {
    /// Repaint the panel in pink (or restore) for the inactive-display ghost.
    func setGhost(_ on: Bool) {
        guard ghost != on else { return }
        ghost = on
        needsDisplay = true
    }
}
