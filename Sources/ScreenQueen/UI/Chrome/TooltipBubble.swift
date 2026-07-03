import AppKit

/// The fun tooltip: a white speech-bubble with a hot-pink outline and Comic Sans text,
/// shown on *every* canvas at once via the ghost mapping (a native `NSView.toolTip`
/// would only show on the truly hovered screen). Click-through.
final class TooltipBubble: NSView {

    private let padding = NSSize(width: 11, height: 7)
    private let corner: CGFloat = 9
    private var text = ""

    /// Comic Sans if the system has it, else a rounded fallback that still reads playful.
    private static let font: NSFont =
        NSFont(name: "Comic Sans MS", size: 13)
        ?? NSFont(name: "ChalkboardSE-Regular", size: 13)
        ?? .systemFont(ofSize: 13, weight: .medium)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: Self.font, .foregroundColor: NSColor(calibratedRed: 0.86, green: 0.16, blue: 0.5, alpha: 1)]
    }

    /// Fit the bubble to `text` and place it below-and-right of `cursor`, clamped on-canvas.
    func show(_ text: String, at cursor: CGPoint, in bounds: NSRect) {
        self.text = text
        let textSize = (text as NSString).size(withAttributes: attributes)
        let size = NSSize(width: ceil(textSize.width) + padding.width * 2,
                          height: ceil(textSize.height) + padding.height * 2)
        let gap: CGFloat = 14
        var origin = CGPoint(x: cursor.x + gap, y: cursor.y - gap - size.height)
        origin.x = min(max(origin.x, 4), bounds.width - size.width - 4)
        origin.y = min(max(origin.y, 4), bounds.height - size.height - 4)
        frame = NSRect(origin: origin, size: size)
        isHidden = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 1.5, dy: 1.5)   // room for the stroke
        let bubble = NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner)
        NSColor.white.withAlphaComponent(0.8).setFill()
        bubble.fill()
        NSColor(calibratedRed: 0.95, green: 0.28, blue: 0.6, alpha: 1).setStroke()
        bubble.lineWidth = 2.5
        bubble.stroke()

        let ts = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: (bounds.width - ts.width) / 2,
                                            y: (bounds.height - ts.height) / 2),
                                withAttributes: attributes)
    }
}
