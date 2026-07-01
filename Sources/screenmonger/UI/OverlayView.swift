import AppKit

/// A big (✕)-in-circle close button in a view's upper-right corner, shared by the
/// arranger and each screen's glass so any screen can dismiss the overlay. Views are
/// flipped (top-left origin), so "upper-right" is max-x, min-y.
enum CloseButton {
    static let radius: CGFloat = 26
    static let margin: CGFloat = 28

    static func frame(in bounds: NSRect) -> NSRect {
        let c = CGPoint(x: bounds.maxX - margin - radius, y: margin + radius)
        return NSRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius)
    }

    static func hit(_ p: CGPoint, in bounds: NSRect) -> Bool {
        let f = frame(in: bounds)
        return hypot(p.x - f.midX, p.y - f.midY) <= radius
    }

    static func draw(in bounds: NSRect) {
        let f = frame(in: bounds), c = CGPoint(x: f.midX, y: f.midY)
        let circle = NSBezierPath(ovalIn: f)
        NSColor.black.withAlphaComponent(0.55).setFill(); circle.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke(); circle.lineWidth = 2; circle.stroke()
        let x = NSBezierPath(); let r = radius * 0.42
        x.move(to: CGPoint(x: c.x - r, y: c.y - r)); x.line(to: CGPoint(x: c.x + r, y: c.y + r))
        x.move(to: CGPoint(x: c.x - r, y: c.y + r)); x.line(to: CGPoint(x: c.x + r, y: c.y - r))
        x.lineWidth = 3; x.lineCapStyle = .round; NSColor.white.setStroke(); x.stroke()
    }
}

/// Draws, on one real display's glass, that display's colored outline plus a
/// reference bar at each seam (in the facing display's color). Both screens show
/// the same window at its fixed point size, so comparing the two bars' *physical*
/// lengths across the seam shows whether a window keeps its size crossing over —
/// equal lengths ⇒ seamless. The view is flipped (top-left origin) to match the
/// screen-local coordinates the bars carry.
final class OverlayView: NSView {

    private var me: DisplaySnapshot?
    private var byID: [CGDirectDisplayID: DisplaySnapshot] = [:]
    private var bars: [SeamBar] = []
    private var colors: [CGDirectDisplayID: NSColor] = [:]
    private var realWidths: [CGDirectDisplayID: CGFloat] = [:]
    private var dim = false
    private let barThickness: CGFloat = 22

    override var isFlipped: Bool { true }

    func configure(me: DisplaySnapshot,
                   byID: [CGDirectDisplayID: DisplaySnapshot],
                   bars: [SeamBar],
                   colors: [CGDirectDisplayID: NSColor],
                   realWidths: [CGDirectDisplayID: CGFloat],
                   dim: Bool) {
        self.me = me
        self.byID = byID
        self.bars = bars
        self.colors = colors
        self.realWidths = realWidths
        self.dim = dim
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let me else { return }
        let selfColor = colors[me.id] ?? .systemGray

        // Dim the whole screen behind the bars while the arranger is open (every
        // screen, including the main — the arranger above is transparent).
        if dim { NSColor.black.withAlphaComponent(0.4).setFill(); bounds.fill() }

        // Screen outline in this display's color.
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 4, dy: 4))
        outline.lineWidth = 6
        selfColor.withAlphaComponent(0.85).setStroke()
        outline.stroke()

        for bar in bars where bar.aID == me.id || bar.bID == me.id {
            let weAreA = (bar.aID == me.id)
            let facingID = weAreA ? bar.bID : bar.aID
            guard byID[facingID] != nil else { continue }
            // Bar is drawn in the *facing* screen's color (outline stays own
            // color), so each bar reads as "this is what's over there" — the
            // clearest to/from indication across the seam.
            let facingColor = colors[facingID] ?? .systemGray

            // The window's point size — the same on both screens (its physical size
            // differs by density). During a zoom preview the real screen is unchanged,
            // so scale by realWidth/prospectiveWidth.
            let factor = (realWidths[me.id] ?? me.bounds.width) / me.bounds.width
            let length = bar.windowPoints * factor

            // The bar's along-seam position is a point offset from this screen's own
            // leading edge (frame-independent), scaled for a zoom preview.
            let along = (weAreA ? bar.localAlongA : bar.localAlongB) * factor
            let rect: NSRect
            if bar.isVertical {
                let x = weAreA ? bounds.width - barThickness : 0 // a = left display
                rect = NSRect(x: x, y: along - length / 2, width: barThickness, height: length)
            } else {
                let y = weAreA ? bounds.height - barThickness : 0 // a = top display
                rect = NSRect(x: along - length / 2, y: y, width: length, height: barThickness)
            }
            drawBar(rect, color: facingColor)
        }
    }

    private func drawBar(_ rect: NSRect, color: NSColor) {
        color.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        let p = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        p.lineWidth = 2; color.setStroke(); p.stroke()
    }
}
