import AppKit

/// A Liquid Glass capsule that brightens on hover — the hover affordance for the
/// arranger's chromeless glass buttons (the button itself has no bezel, so the glass
/// *is* the interactive surface). Tracks the mouse over its own bounds and animates
/// its `tintColor` between a resting and a hovered wash.
@available(macOS 26.0, *)
final class HoverGlassView: NSGlassEffectView {

    /// Resting tint (nil for an untinted glass, e.g. Reset/Undo).
    private let baseTint: NSColor?
    /// Tint while hovered: the base lifted toward white, or a faint white wash when
    /// there's no base tint.
    private let hoverTint: NSColor
    /// The wrapped button — hover only lights up while it's enabled (a disabled Undo
    /// gives no feedback).
    weak var button: NSButton?

    init(baseTint: NSColor?) {
        self.baseTint = baseTint
        if let baseTint {
            self.hoverTint = (baseTint.blended(withFraction: 0.35, of: .white) ?? baseTint)
        } else {
            self.hoverTint = NSColor.white.withAlphaComponent(0.22)
        }
        super.init(frame: .zero)
        tintColor = baseTint
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard button?.isEnabled ?? true else { return }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().tintColor = hoverTint }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; animator().tintColor = baseTint }
    }
}

extension NSImage {
    /// A copy rotated counter-clockwise by `degrees`, preserving `isTemplate` so a symbol
    /// image still tints correctly. The canvas keeps the original size (the glyph rotates
    /// within it), which is fine for a roughly-square symbol.
    func rotatedCCW(degrees: CGFloat, offset: CGSize = .zero) -> NSImage {
        let radians = degrees * .pi / 180
        let rotated = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.translateBy(x: offset.width, y: offset.height)   // small positional nudge
            // Rotate about the image center.
            ctx.translateBy(x: self.size.width / 2, y: self.size.height / 2)
            ctx.rotate(by: radians)
            ctx.translateBy(x: -self.size.width / 2, y: -self.size.height / 2)
            self.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        rotated.isTemplate = isTemplate
        return rotated
    }
}
