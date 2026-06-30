import AppKit

/// Draws, on one real display's glass, that display's colored outline plus — at
/// each seam — a single reference bar in the display's own color, hugging the
/// seam and centered on the overlap midpoint.
///
/// Same UI idea as the calibration tool: each screen shows one bar representing
/// the same reference element (a fixed point size). Because pixels are square,
/// that bar's physical length is `referencePoints / pointsPerInch`, so comparing
/// the two bars *across the seam* tells you directly whether a window keeps its
/// size when dragged across — equal physical lengths ⇒ seamless.
///
/// The view is flipped (top-left origin) so it shares CoreGraphics' global
/// coordinate convention: a global point maps to local by subtracting this
/// display's origin, since the overlay window exactly covers the screen.
final class OverlayView: NSView {

    private var me: DisplaySnapshot?
    private var byID: [CGDirectDisplayID: DisplaySnapshot] = [:]
    private var junctions: [Junction] = []
    private var colors: [CGDirectDisplayID: NSColor] = [:]

    /// Reference element length, in points (anchored to 10 cm on the reference
    /// screen by the controller), capped per seam to fit the overlap.
    private var referenceLengthPoints: CGFloat = 160
    private let barThickness: CGFloat = 22

    override var isFlipped: Bool { true }

    func configure(me: DisplaySnapshot,
                   byID: [CGDirectDisplayID: DisplaySnapshot],
                   junctions: [Junction],
                   colors: [CGDirectDisplayID: NSColor],
                   referenceLengthPoints: CGFloat) {
        self.me = me
        self.byID = byID
        self.junctions = junctions
        self.colors = colors
        self.referenceLengthPoints = referenceLengthPoints
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let me else { return }
        let origin = me.bounds.origin
        let selfColor = colors[me.id] ?? .systemGray

        // Screen outline in this display's color.
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 4, dy: 4))
        outline.lineWidth = 6
        selfColor.withAlphaComponent(0.85).setStroke()
        outline.stroke()

        for j in junctions where j.aID == me.id || j.bID == me.id {
            let facingID = (j.aID == me.id) ? j.bID : j.aID
            guard let facing = byID[facingID] else { continue }
            // Bar is drawn in the *facing* screen's color (outline stays own
            // color), so each bar reads as "this is what's over there" — the
            // clearest to/from indication across the seam.
            let facingColor = colors[facingID] ?? .systemGray

            // Same reference length (points) on both screens, capped to overlap.
            let length = min(referenceLengthPoints, overlapPoints(me, facing) * 0.9)

            let rect: NSRect
            if j.isVertical {
                let along = j.midpoint - origin.y
                let seamAtRight = (j.aID == me.id) // we're the left display
                let x = seamAtRight ? bounds.width - barThickness : 0
                rect = NSRect(x: x, y: along - length / 2, width: barThickness, height: length)
            } else {
                let along = j.midpoint - origin.x
                let seamAtBottom = (j.aID == me.id) // we're the top display
                let y = seamAtBottom ? bounds.height - barThickness : 0
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

    /// Overlap length (points) of the seam shared by `a` and `b`.
    private func overlapPoints(_ a: DisplaySnapshot, _ b: DisplaySnapshot) -> CGFloat {
        let A = a.bounds, B = b.bounds, tol: CGFloat = 2
        if abs(A.maxX - B.minX) <= tol || abs(B.maxX - A.minX) <= tol {
            return max(0, min(A.maxY, B.maxY) - max(A.minY, B.minY))
        }
        return max(0, min(A.maxX, B.maxX) - max(A.minX, B.minX))
    }
}
