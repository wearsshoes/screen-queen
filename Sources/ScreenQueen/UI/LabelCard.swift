import AppKit

/// The frosted info card on a tile: the display's name / resolution / ppi on a real
/// *backdrop-blurred* plate (an `NSVisualEffectView` blurs the tile wallpaper drawn behind
/// it), with a translucent wash on top — pink on the active tile, dark on the rest.
///
/// It's a subview (not drawn in `Arranger.draw`) because a live backdrop blur only blurs
/// what's *behind* the view, and view content composites above the host's `draw(_:)`
/// output. The stacking within the card is: blur (back) → wash → text overlay (front),
/// since subviews composite above their host's own `draw`, so the text must be its own
/// view on top of the blur. One card per (canvas, display); the Arranger repositions it to
/// the tile each frame and feeds it `Content`.
final class LabelCard: NSView {

    /// One text line: string, font, fill.
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

    /// Click-through: the card is decoration over the tile; the tile handles interaction.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ content: Content) {
        // The wash over the blur: pink on the active tile, dark otherwise.
        let wash = content.selected
            ? (NSColor.systemPink.blended(withFraction: 0.35, of: .black) ?? .systemPink).withAlphaComponent(0.5)
            : NSColor.black.withAlphaComponent(0.4)
        blur.layer?.backgroundColor = wash.cgColor
        textLayer.content = content
        textLayer.frame = bounds
        textLayer.wantsLayer = true
        // Render the text at 2× the display's backing (min 2×) — the ornate script name has
        // hairline strokes that read soft at 1×; supersampling gives them more pixels. On a
        // non-Retina (1×) monitor this is the difference between crisp and mushy.
        textLayer.layer?.contentsScale = max(2, (window?.backingScaleFactor ?? 2) * 2)
        textLayer.needsDisplay = true
    }

    /// The text, drawn in a view layered *above* the blur.
    private final class TextOverlay: NSView {
        var content = Content()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Round to the nearest whole device pixel so each line sits on the grid instead
        /// of straddling it — a fractional baseline/x smears the glyphs, worst on the big
        /// script name.
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
