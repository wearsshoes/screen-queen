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

/// One control's *ghost self*: the whole element as a solid pink shape (its real self
/// is the live control; this is the pink twin). Positioned and sized by the
/// projection, so the bar's shapes still read left-to-right — feed, reset, undo,
/// slider, done — just in pink.
final class GhostElementLayer: CAShapeLayer {

    override init() {
        super.init()
        let pink = ArrangerState.seamPalette[0]
        fillColor = pink.withAlphaComponent(0.85).cgColor
        strokeColor = (pink.blended(withFraction: 0.35, of: .white) ?? pink).cgColor
        lineWidth = 1.5
        isHidden = true
    }

    /// Fit the pink shape to `rect` (this canvas's view coords — may run off-screen,
    /// which is fine). `radius` is the corner already scaled to the projection.
    func update(around rect: CGRect, radius: CGFloat) {
        guard !rect.isEmpty else { isHidden = true; return }
        frame = rect
        let radius = max(0, min(radius, rect.height / 2))
        path = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size),
                      cornerWidth: radius, cornerHeight: radius, transform: nil)
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
            func paint(_ element: GhostKey.Element, _ srcRect: CGRect, corner: CGFloat) {
                let key = GhostKey(display: srcID, element: element)
                let p = project(srcRect)
                ghostLayer(key).update(around: p.rect, radius: corner * p.scale)
                live.insert(key)
            }
            // The bar buttons (the slider + scope share one glass pill: project the
            // whole pill once, keyed on the slider).
            for (control, view) in source.barCapsules where control != .scope {
                let cap = (control == .slider ? (source.sliderPillView ?? view) : view)
                let r = cap.convert(cap.bounds, to: source)
                paint(.bar(control), r, corner: r.height / 2)
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
