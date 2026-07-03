import AppKit

/// The frosted info card on a tile: name / resolution / ppi on a real backdrop-blurred
/// plate with a translucent wash — pink on the active tile, dark on the rest.
///
/// It's a subview (not drawn in `Arranger.draw`) because a live backdrop blur only blurs
/// what's *behind* the view, and subviews composite above the host's `draw(_:)` output —
/// which is also why the text must be its own view on top of the blur.
final class LabelCard: NSView {

    struct Line { let text: String; let font: NSFont; let color: NSColor }
    struct Content {
        var lines: [Line] = []
        var selected = false
        var gap: CGFloat = 3
    }

    private let blur = NSVisualEffectView()
    private let textLayer = TextOverlay()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        blur.blendingMode = .withinWindow    // blur what's drawn behind it in this window
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 11
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)

        textLayer.autoresizingMask = [.width, .height]
        addSubview(textLayer)                // in front of the blur, so the text shows
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Click-through: the card is decoration; the tile handles interaction.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ content: Content) {
        let wash = content.selected
            ? (NSColor.systemPink.blended(withFraction: 0.35, of: .black) ?? .systemPink).withAlphaComponent(0.5)
            : NSColor.black.withAlphaComponent(0.4)
        blur.layer?.backgroundColor = wash.cgColor
        textLayer.content = content
        textLayer.frame = bounds
        textLayer.wantsLayer = true
        // Supersample the text (2× backing, min 2×): the ornate script name has hairline
        // strokes that read mushy at 1× on a non-Retina monitor.
        textLayer.layer?.contentsScale = max(2, (window?.backingScaleFactor ?? 2) * 2)
        textLayer.needsDisplay = true
    }

    /// The text, drawn in a view layered *above* the blur.
    private final class TextOverlay: NSView {
        var content = Content()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Pixel-snap — a fractional baseline/x smears the glyphs.
        private func snap(_ v: CGFloat) -> CGFloat {
            let b = window?.backingScaleFactor ?? 2
            return (v * b).rounded() / b
        }

        override func draw(_ dirtyRect: NSRect) {
            let total = content.lines.reduce(0) { $0 + ($1.text as NSString).size(withAttributes: [.font: $1.font]).height }
                + content.gap * CGFloat(max(0, content.lines.count - 1))
            var y = bounds.midY + total / 2
            for line in content.lines {
                let s = (line.text as NSString).size(withAttributes: [.font: line.font])
                y -= s.height
                let attrs: [NSAttributedString.Key: Any] = [.font: line.font, .foregroundColor: line.color]
                (line.text as NSString).draw(at: CGPoint(x: snap((bounds.width - s.width) / 2), y: snap(y)),
                                             withAttributes: attrs)
                y -= content.gap
            }
        }
    }
}
