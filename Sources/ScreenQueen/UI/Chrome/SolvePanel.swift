import SwiftUI

/// What the "what she sees" panel shows: the live reconstructed *point* arrangement —
/// the actual solve `seamBars` uses — plus the ghost flag (inactive stages repaint
/// in pink).
struct SolvePanelContent {
    var rects: [(id: CGDirectDisplayID, rect: CGRect, ambiguous: Bool)] = []
    var seams: [(a: CGDirectDisplayID, b: CGDirectDisplayID, vertical: Bool, color: Color)] = []
    var ghost = false
}

/// "What she sees", drawn in a SwiftUI `Canvas` — the dry run for the big schematic
/// Canvas port. Point space is y-down like Canvas itself, so the old y-flip is gone.
/// Point rects are outlined (red = resolved through an ambiguous >1-preimage inverse);
/// seams draw in their palette color over the outlines — the seam is the shared edge,
/// so its color wins there.
struct SolvePanelView: View {
    var content: SolvePanelContent

    private static let titleBarHeight: CGFloat = 16

    var body: some View {
        Canvas { ctx, size in
            let bounds = CGRect(origin: .zero, size: size)
            let ink: Color = content.ghost ? ChromeMetrics.ghostPink : .white
            let plateColor: Color = content.ghost
                ? Color(nsColor: (SeamPalette.colors[0].blended(withFraction: 0.55, of: .black) ?? .black))
                : .black

            // Dark rounded plate with a lighter title strip; ghosting tints it toward pink.
            let plate = Path(roundedRect: bounds, cornerRadius: 6)
            ctx.fill(plate, with: .color(plateColor.opacity(0.6)))
            var strip = ctx
            strip.clip(to: plate)
            strip.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: Self.titleBarHeight)),
                       with: .color(ink.opacity(0.12)))

            let ambiguous = content.rects.contains { $0.ambiguous }
            let title = Copy.solvePanelTitle + (ambiguous ? Copy.solvePanelAmbiguous : "")
            ctx.draw(Text(title).font(.system(size: 9, weight: .bold)).foregroundStyle(ink.opacity(0.8)),
                     at: CGPoint(x: 6, y: Self.titleBarHeight / 2), anchor: .leading)

            // Fit the point-rect union into the body.
            guard content.rects.count >= 2 else { return }
            var uni = content.rects[0].rect
            for e in content.rects.dropFirst() { uni = uni.union(e.rect) }
            guard uni.width > 0, uni.height > 0 else { return }
            let area = CGRect(x: 0, y: Self.titleBarHeight,
                              width: size.width, height: size.height - Self.titleBarHeight)
                .insetBy(dx: 10, dy: 10)
            let s = min(area.width / uni.width, area.height / uni.height)
            func map(_ r: CGRect) -> CGRect {
                CGRect(x: area.minX + (r.minX - uni.minX) * s,
                       y: area.minY + (r.minY - uni.minY) * s,
                       width: r.width * s, height: r.height * s)
            }

            for e in content.rects {
                let vr = map(e.rect)
                let stroke: Color = e.ambiguous ? .red : ink
                ctx.stroke(Path(vr), with: .color(stroke), lineWidth: e.ambiguous ? 2 : 1)
                ctx.draw(Text("\(e.id % 1000)").font(.system(size: 9)).foregroundStyle(stroke),
                         at: CGPoint(x: vr.minX + 2, y: vr.midY), anchor: .leading)
            }

            // The seam pair arrives in arbitrary order, so sort the two view rects
            // geometrically — the line must sit on the shared edge, not wherever (a, b)
            // happened to fall.
            let byID = Dictionary(content.rects.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
            for seam in content.seams {
                guard let ra = byID[seam.a], let rb = byID[seam.b] else { continue }
                let va = map(ra), vb = map(rb)
                var line = Path()
                if seam.vertical {
                    let (l, r) = va.midX <= vb.midX ? (va, vb) : (vb, va)   // left tile by center
                    let x = (l.maxX + r.minX) / 2
                    line.move(to: CGPoint(x: x, y: max(va.minY, vb.minY)))
                    line.addLine(to: CGPoint(x: x, y: min(va.maxY, vb.maxY)))
                } else {
                    let (t, b) = va.midY <= vb.midY ? (va, vb) : (vb, va)   // upper tile (y-down)
                    let y = (t.maxY + b.minY) / 2
                    line.move(to: CGPoint(x: max(va.minX, vb.minX), y: y))
                    line.addLine(to: CGPoint(x: min(va.maxX, vb.maxX), y: y))
                }
                ctx.stroke(line, with: .color(seam.color), lineWidth: 3)
            }
        }
    }
}

/// The panel's hosting view: draggable (the whole panel is the handle), hidden when
/// there's nothing to say about a solo girl, ghost-tinted via the content model.
final class SolvePanelHost: NSHostingView<SolvePanelView> {

    /// Dragging reports the desired origin here instead of moving the panel itself —
    /// the stage stores it as a centre-relative inch offset in shared state, and every
    /// stage repositions on the resulting notify.
    var onMoved: ((CGPoint) -> Void)?

    private var content = SolvePanelContent()
    private var ghost = false

    func update(_ content: SolvePanelContent) {
        self.content = content
        apply()
    }

    private func apply() {
        var c = content
        c.ghost = ghost
        rootView = SolvePanelView(content: c)
        isHidden = content.rects.count < 2   // nothing to say about a solo girl
    }

    /// The whole panel is the drag handle (and nothing outside it).
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
}

extension SolvePanelHost: GhostTintable {
    /// Repaint the panel in pink (or restore) for the inactive-display ghost.
    func setGhost(_ on: Bool) {
        guard ghost != on else { return }
        ghost = on
        apply()
    }
}
