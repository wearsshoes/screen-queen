import AppKit

/// The resolution slider's cell, drawing its own bar so it never greys out: macOS dims a
/// control when its window isn't key, and only one arranger overlay is key at a time —
/// the stock track would grey out and override the ghost pink. The knob is left to `super`.
final class ArrangerSliderCell: NSSliderCell {
    /// Track colour: the ghost pink on inactive canvases, nil for the normal look.
    var barTint: NSColor?

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard let barTint else { super.drawBar(inside: rect, flipped: flipped); return }
        // A faint full-width groove, the tint filling only left of the knob.
        let h: CGFloat = 4
        let track = NSRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
        let groove = NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2)
        NSColor.white.withAlphaComponent(0.25).setFill()
        groove.fill()

        let knobX = knobRect(flipped: flipped).midX
        let filled = NSRect(x: track.minX, y: track.minY,
                            width: max(0, knobX - track.minX), height: h)
        let fill = NSBezierPath(roundedRect: filled, xRadius: h / 2, yRadius: h / 2)
        barTint.setFill()
        fill.fill()
    }
}

/// A Liquid Glass capsule that brightens on hover — the hover affordance for the
/// chromeless glass buttons (the glass *is* the interactive surface).
@available(macOS 26.0, *)
final class HoverGlassView: NSGlassEffectView {

    /// Resting tint (nil for untinted glass, e.g. Reset/Undo).
    private let baseTint: NSColor?
    private let hoverTint: NSColor
    /// The wrapped button — hover only lights up while it's enabled.
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

    /// The resting tint (glass isn't washed in ghost mode — only the icon is).
    private var restingTint: NSColor? { baseTint }

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
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; animator().tintColor = restingTint }
    }
}

@available(macOS 26.0, *)
extension HoverGlassView: GhostTintable {
    /// Ghost mode tints only the *icon* — a washed capsule read as a solid pink blob.
    func setGhost(_ on: Bool) {
        button?.contentTintColor = on ? VirtualMouse.pink : .labelColor
    }
}

/// The resolution slider's glass pill. In ghost mode only its *contents* go pink — the
/// track fill and the A/a end glyphs — while the glass keeps its clear look.
@available(macOS 26.0, *)
final class GhostGlassPill: NSGlassEffectView, GhostTintable {
    weak var slider: NSSlider?
    var glyphs: [NSTextField] = []

    func setGhost(_ on: Bool) {
        (slider?.cell as? ArrangerSliderCell)?.barTint = on ? VirtualMouse.pink : nil
        slider?.needsDisplay = true
        for g in glyphs { g.textColor = on ? VirtualMouse.pink : .labelColor }
    }
}

extension NSSlider: GhostTintable {
    /// Pink the track via the custom cell (immune to non-key greying), else the plain fill.
    public func setGhost(_ on: Bool) {
        if let cell = cell as? ArrangerSliderCell {
            cell.barTint = on ? VirtualMouse.pink : nil
            needsDisplay = true
        } else {
            trackFillColor = on ? VirtualMouse.pink : nil
        }
    }
}

/// Ghosts the pre-macOS-26 HUD button box: pinks its border (no glass to tint).
@MainActor final class HUDBoxGhost: GhostTintable {
    private weak var box: NSVisualEffectView?
    init(box: NSVisualEffectView) { self.box = box }
    func setGhost(_ on: Bool) {
        box?.layer?.borderColor = (on ? VirtualMouse.pink : NSColor.white.withAlphaComponent(0.12)).cgColor
        box?.layer?.borderWidth = on ? 1.5 : 0.5
    }
}

extension NSImage {
    /// This image as a `CGImage` (full bounds), or nil.
    var asCGImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
