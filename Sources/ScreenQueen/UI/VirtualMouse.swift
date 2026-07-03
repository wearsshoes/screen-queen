import AppKit

/// The ghost of the *active* screen, shown on every other screen. Two parts, both
/// riding the shared affine plane (minimap) transform so they never disagree:
///
/// - **The ghost mouse** (`GhostCursorLayer`): the real cursor, mirrored onto this
///   canvas's minimap. Updated on every mouse move.
/// - **The ghost chrome** (`ghostChrome`): a container of pink, non-interactive
///   *twins* of the UI elements — each element's own look, tinted pink — built once
///   and projected together by a single container transform. When the cursor is on
///   another screen, that screen's controls appear here in their true relative place
///   (free to fall off-screen; the minimap itself never rescales).
///
/// The chrome transform is recomputed only when the active screen changes; the ghost
/// mouse moves continuously. Adding a UI element means adding its twin to the
/// container once — no per-element projection code.
enum VirtualMouse {
    /// Feature flag: the ghost mouse (arrow mirrored onto the minimap).
    static let ghostMouseEnabled = true
    /// Feature flag: the ghost chrome (projected pink twins of the controls).
    static let ghostChromeEnabled = true

    /// A template symbol tinted white for legibility on a pink twin (the control's
    /// own glyph, from its image asset — not a view snapshot). nil passes through.
    static func tinted(_ image: NSImage?) -> CGImage? {
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
}

/// The six bar controls, by role. Keys a twin (and looks up its glyph).
enum BarControl: CaseIterable, Hashable { case feed, reset, undo, slider, scope, done }

/// A UI element that has a pink ghost twin in the container.
enum GhostChromeElement: Hashable {
    case bar(BarControl)
    case banner(ArrangerState.CountdownKind, CountdownBanner.Role)
    case panel
}

/// One control's *ghost self*: the same element, pink and non-interactive — a
/// translucent pink capsule (it keeps the glass's see-through feel) carrying the
/// control's own icon, so a ghosted Done still wears its checkmark.
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

    /// Lay the pink twin at `frame` (the control's real frame in the canvas — the
    /// container transform then projects the whole bundle). `iconImage` is the
    /// control's own glyph (nil for the slider/panel).
    func update(frame rect: CGRect, radius: CGFloat, iconImage: CGImage?) {
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

/// The ghost mouse: a dashed, glowing, translucent hot-pink arrow. Obviously a ghost.
/// Its `position` is the arrow's *tip* (anchor at the top-left of the glyph).
final class GhostCursorLayer: CAShapeLayer {

    override init() {
        super.init()
        let art: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.5), CGPoint(x: 3.9, y: 12.8),
            CGPoint(x: 6.3, y: 18.4), CGPoint(x: 9.0, y: 17.2), CGPoint(x: 6.6, y: 11.6),
            CGPoint(x: 12.0, y: 11.6),
        ]
        let s: CGFloat = 1.35
        let h: CGFloat = 18.4 * s
        let path = CGMutablePath()
        path.addLines(between: art.map { CGPoint(x: $0.x * s, y: h - $0.y * s) })
        path.closeSubpath()
        self.path = path
        bounds = CGRect(x: 0, y: 0, width: 12.0 * s, height: h)
        anchorPoint = CGPoint(x: 0, y: 1)           // the tip is the hotspot
        let pink = ArrangerState.seamPalette[0]
        fillColor = pink.withAlphaComponent(0.35).cgColor
        strokeColor = pink.cgColor
        lineWidth = 2
        lineDashPattern = [4, 3]
        lineJoin = .round
        opacity = 0.95
        shadowColor = pink.cgColor
        shadowOpacity = 0.9
        shadowRadius = 6
        shadowOffset = .zero
        isHidden = true
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Per-canvas rendering

extension Arranger {

    /// Position the pink twins at this canvas's own chrome (built once, laid out on
    /// every layout change — the container transform does the projecting, not this).
    /// Adding a UI element = add one `place(...)` line here.
    func layoutGhostTwins() {
        guard VirtualMouse.ghostChromeEnabled else { return }
        let container = ensureGhostChrome()
        var present: Set<GhostChromeElement> = []
        func place(_ element: GhostChromeElement, _ frame: CGRect, radius: CGFloat, icon: NSImage?) {
            let twin = ghostTwins[element] ?? {
                let l = GhostElementLayer(); container.addSublayer(l); ghostTwins[element] = l; return l
            }()
            twin.update(frame: frame, radius: radius, iconImage: VirtualMouse.tinted(icon))
            present.insert(element)
        }
        // The bar buttons (the slider + scope share one glass pill: one twin, keyed
        // on the slider). Each carries its own glyph.
        for (control, view) in barCapsules where control != .scope {
            let cap = (control == .slider ? (sliderPillView ?? view) : view)
            let f = cap.convert(cap.bounds, to: self)
            place(.bar(control), f, radius: f.height / 2, icon: barButtonImage(control))
        }
        if let banner, !banner.isHidden {
            for kind in ArrangerState.CountdownKind.allCases {
                for role in [CountdownBanner.Role.keep, .act] {
                    if let r = banner.buttonRect(kind: kind, role: role) {
                        place(.banner(kind, role), banner.convert(r, to: self), radius: 8, icon: nil)
                    }
                }
            }
        }
        if !solvePanel.isHidden { place(.panel, solvePanel.frame, radius: 6, icon: nil) }
        for (element, twin) in ghostTwins where !present.contains(element) { twin.isHidden = true }
    }

    /// Project the whole chrome bundle: set the container's single transform so the
    /// twins appear where `active`'s controls project onto this canvas's minimap.
    /// `active == nil` (this IS the active screen) hides the ghost — real chrome shows.
    /// Recomputed only when the active screen changes.
    func projectGhostChrome(active: Arranger?) {
        let container = ensureGhostChrome()
        guard VirtualMouse.ghostChromeEnabled, let active, active !== self else {
            container.isHidden = true; return
        }
        ghostAffine = affine(from: active)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        container.setAffineTransform(ghostAffine)
        container.isHidden = false
        CATransaction.commit()
    }

    /// Move the ghost mouse. `cursorActivePoint` is the real cursor in the active
    /// canvas's view coords; it rides the *same* affine as the chrome, so the arrow
    /// and the ghost controls agree. Hidden on the active screen (real cursor there).
    func updateGhostArrow(cursorActivePoint: CGPoint?, isActive: Bool) {
        guard VirtualMouse.ghostMouseEnabled else { return }
        let arrow = ensureGhostArrow()
        guard !isActive, let p = cursorActivePoint else { arrow.isHidden = true; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arrow.position = p.applying(ghostAffine)
        arrow.isHidden = false
        CATransaction.commit()
    }

    /// The affine that maps the active canvas's view space onto this canvas's, via the
    /// shared plane (both transforms are scale+translate, so the composition is too).
    /// Evaluated at three points, so the y-flips take care of themselves.
    private func affine(from active: Arranger) -> CGAffineTransform {
        guard let myT = drawTransform(currentRects()),
              let actT = active.drawTransform(active.currentRects()) else { return .identity }
        func map(_ p: CGPoint) -> CGPoint { myT.viewPoint(actT.planePoint(p)) }
        let o = map(.zero), ex = map(CGPoint(x: 1, y: 0)), ey = map(CGPoint(x: 0, y: 1))
        return CGAffineTransform(a: ex.x - o.x, b: ex.y - o.y,
                                 c: ey.x - o.x, d: ey.y - o.y, tx: o.x, ty: o.y)
    }

    private func ensureGhostChrome() -> CALayer {
        if let c = ghostChrome { return c }
        wantsLayer = true
        let c = CALayer()
        c.anchorPoint = .zero
        c.frame = bounds
        c.zPosition = 5   // above the schematic layers (particles 1, glow 2, panel 3)
        c.isHidden = true
        layer?.addSublayer(c)
        ghostChrome = c
        return c
    }

    private func ensureGhostArrow() -> GhostCursorLayer {
        if let a = ghostArrow { return a }
        wantsLayer = true
        let a = GhostCursorLayer()
        a.zPosition = 6
        layer?.addSublayer(a)
        ghostArrow = a
        return a
    }

    /// The SF Symbol the real button wears, for the twin to carry too. (The slider
    /// pill has no single glyph.)
    private func barButtonImage(_ control: BarControl) -> NSImage? {
        switch control {
        case .feed: return feedButton.image
        case .reset: return resetButton.image
        case .undo: return undoButton.image
        case .done: return doneButton.image
        case .slider, .scope: return nil
        }
    }
}
