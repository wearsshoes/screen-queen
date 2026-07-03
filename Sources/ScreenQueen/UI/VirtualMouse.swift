import AppKit

/// The ghost chrome. On every arranger canvas, a pink outline *image* of every
/// OTHER screen's controls — the bottom-bar buttons and the "what she sees" panel —
/// rendered where they sit on that original screen, projected through the same affine
/// plane (minimap) transform the schematic rides. So if a screen goes dark, every
/// other screen still shows you its controls in their true relative place, and you
/// can steer your real mouse over and fix it.
///
/// They are just images: not clickable, driven only by the layout (no cursor
/// tracking, no event monitors), and free to fall partly or fully off this screen —
/// that's fine, it's an honest projection of where the control really is.
enum VirtualMouse {
    /// Feature flag: draw the projected ghost chrome at all.
    static let ghostChromeEnabled = true
}

/// The six bar controls, by role — every canvas has the same bar, so `.done` here is
/// `.done` everywhere. Keys a projected ghost image.
enum BarControl: CaseIterable, Hashable { case feed, reset, undo, slider, scope, done }

/// One projected ghost image: which source display it belongs to and which control.
struct GhostKey: Hashable {
    let display: CGDirectDisplayID
    let element: Element
    enum Element: Hashable {
        case bar(BarControl)
        case banner(ArrangerState.CountdownKind, CountdownBanner.Role)
        case panel
    }
}

/// One control's *ghost self*: the same element, pink and non-interactive — a
/// translucent pink capsule (it keeps the glass's see-through feel) carrying the
/// control's own icon, so a ghosted Done still wears its checkmark. Positioned and
/// sized by the projection.
final class GhostElementLayer: CALayer {

    private let icon = CALayer()

    override init() {
        super.init()
        let pink = ArrangerState.seamPalette[0]
        backgroundColor = pink.withAlphaComponent(0.38).cgColor   // translucent like the glass
        borderColor = pink.withAlphaComponent(0.9).cgColor
        borderWidth = 1.5
        masksToBounds = true
        icon.contentsGravity = .resizeAspect
        addSublayer(icon)
        isHidden = true
    }

    /// Fit the pink twin to `rect` (this canvas's view coords — may run off-screen,
    /// which is fine). `radius` is the corner already scaled to the projection;
    /// `iconImage` is the control's own glyph (nil for the slider/panel).
    func update(around rect: CGRect, radius: CGFloat, iconImage: CGImage?) {
        guard !rect.isEmpty else { isHidden = true; return }
        frame = rect
        cornerRadius = max(0, min(radius, rect.height / 2))
        if let iconImage {
            icon.contents = iconImage
            let s = min(bounds.width, bounds.height) * 0.55
            icon.frame = CGRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
            icon.isHidden = false
        } else {
            icon.isHidden = true
        }
        isHidden = false
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Per-canvas rendering

extension Arranger {

    /// Redraw this canvas's ghost chrome: project every `others` canvas's controls
    /// onto this one through the shared affine transform (`Transform.planePoint` back
    /// to the plane, `viewPoint` forward onto this canvas). Called by ArrangerWindows
    /// whenever the layout settles — never on a mouse event. Layer moves only.
    func renderGhostChrome(from others: [Arranger]) {
        guard VirtualMouse.ghostChromeEnabled, let myT = drawTransform(currentRects()) else {
            hideGhostChrome(); return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        var live: Set<GhostKey> = []
        for source in others {
            guard let srcID = source.centerID,
                  let srcT = source.drawTransform(source.currentRects()) else { continue }
            // A rect in the source canvas's view coords → the plane → this canvas.
            // Both transforms are scale+translate, so a rect maps to a rect.
            func project(_ r: CGRect) -> (rect: CGRect, scale: CGFloat) {
                let a = myT.viewPoint(srcT.planePoint(CGPoint(x: r.minX, y: r.minY)))
                let b = myT.viewPoint(srcT.planePoint(CGPoint(x: r.maxX, y: r.maxY)))
                let out = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                 width: abs(b.x - a.x), height: abs(b.y - a.y))
                let scale = r.height > 0 ? out.height / r.height : 1
                return (out, scale)
            }
            func paint(_ element: GhostKey.Element, _ srcRect: CGRect, corner: CGFloat, icon: CGImage? = nil) {
                let key = GhostKey(display: srcID, element: element)
                let p = project(srcRect)
                ghostLayer(key).update(around: p.rect, radius: corner * p.scale, iconImage: icon)
                live.insert(key)
            }
            // The bar buttons (the slider + scope share one glass pill: project the
            // whole pill once, keyed on the slider). Each carries its own glyph.
            for (control, view) in source.barCapsules where control != .scope {
                let cap = (control == .slider ? (source.sliderPillView ?? view) : view)
                let r = cap.convert(cap.bounds, to: source)
                paint(.bar(control), r, corner: r.height / 2,
                      icon: Self.tinted(source.barButtonImage(control)))
            }
            if let banner = source.banner, !banner.isHidden {
                for kind in ArrangerState.CountdownKind.allCases {
                    for role in [CountdownBanner.Role.keep, .act] {
                        if let r = banner.buttonRect(kind: kind, role: role) {
                            paint(.banner(kind, role), banner.convert(r, to: source), corner: 8)
                        }
                    }
                }
            }
            if !source.solvePanel.isHidden { paint(.panel, source.solvePanel.frame, corner: 6) }
        }
        for (key, layer) in ghostLayers where !live.contains(key) { layer.isHidden = true }
    }

    func hideGhostChrome() { ghostLayers.values.forEach { $0.isHidden = true } }

    /// The SF Symbol image the real button wears, for the ghost to carry too. (The
    /// slider pill has no glyph.)
    func barButtonImage(_ control: BarControl) -> NSImage? {
        switch control {
        case .feed: return feedButton.image
        case .reset: return resetButton.image
        case .undo: return undoButton.image
        case .done: return doneButton.image
        case .slider, .scope: return nil
        }
    }

    /// A template symbol tinted white for legibility on the pink twin. nil passes
    /// through (no glyph → no icon layer).
    fileprivate static func tinted(_ image: NSImage?) -> CGImage? {
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        let out = NSImage(size: image.size)
        out.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSColor.white.withAlphaComponent(0.92).set()
        CGRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        out.unlockFocus()
        var r = CGRect(origin: .zero, size: image.size)
        return out.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }

    private func ghostLayer(_ key: GhostKey) -> GhostElementLayer {
        if let layer = ghostLayers[key] { return layer }
        wantsLayer = true
        let layer = GhostElementLayer()
        layer.zPosition = 5   // above the schematic layers (particles 1, glow 2, panel 3)
        self.layer?.addSublayer(layer)
        ghostLayers[key] = layer
        return layer
    }
}
