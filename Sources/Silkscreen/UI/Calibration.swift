import AppKit

/// Where a calibration bar sits on the screen it's drawn on: which edge it abuts
/// and its center offset from that screen's leading edge along the seam axis.
/// Derived from `SchematicLayout.Seam` so calibration and the arranger place bars
/// the same way, with no per-screen coordinate flips.
private struct BarPlacement {
    enum Edge { case left, right, top, bottom }
    let edge: Edge
    let along: CGFloat          // center along the seam, in this screen's local frame (y-up)

    /// A vertical seam (left/right edge) runs the bar vertically; horizontal runs it across.
    var lengthIsVertical: Bool { edge == .left || edge == .right }

    /// The bar's placement on the screen `frame` sharing seam `s` with a neighbor,
    /// where `selfIsA` picks this screen's side of the seam (a = left/top).
    /// AppKit is y-up; `SchematicLayout` (CG) is y-down, so the vertical-seam center
    /// is flipped within the screen height.
    init(seam s: SchematicLayout.Seam, screen frame: CGRect, selfIsA: Bool) {
        let along = s.localCenter(on: frame)
        if s.vertical {
            edge = selfIsA ? .right : .left
            self.along = frame.height - along     // CG y-down → AppKit y-up
        } else {
            edge = selfIsA ? .bottom : .top        // a is on top (CG maxY == b.minY)
            self.along = along
        }
    }
}

private let barThickness: CGFloat = 28

/// Visual "match the bars" calibration. Because pixels are square, PPI is the
/// same in both axes, so a single length suffices — no need for a 2D box.
///
/// Two resizable bars hug the shared seam, one per display, starting at the full
/// shared edge. The user drags either until they look the same real length. The
/// reference display is trusted (its EDID PPI), so its bar's physical length
/// (points ÷ refPPI) is known; at a match the target's bar is that same length, so:
///
///   pointsPerInch_target = targetBarPoints / (refBarPoints / refPPI)
///
/// Starting both at the full seam overlap makes the bars as long as possible, so
/// the user's matching error is a smaller fraction of the length.
@MainActor
final class CalibrationController {

    private var refWindow: NSWindow?
    private var targetWindow: NSWindow?
    private var panel: CalibrationPanel?
    private var target: DisplaySnapshot?

    private var refPPT: Double = 0             // trusted reference PPI (source of truth)
    private var refLengthPoints: CGFloat = 0   // live reference bar length
    private var targetLengthPoints: CGFloat = 0 // live target bar length

    /// Called after a save or cancel so the owner can refresh.
    var onComplete: (() -> Void)?

    func begin(target: DisplaySnapshot, reference: DisplaySnapshot) {
        guard let refPPT = reference.pointsPerInch, refPPT > 0,
              let refScreen = screen(for: reference.id),
              let targetScreen = screen(for: target.id) else {
            onComplete?()
            return
        }
        cancel()
        self.target = target
        self.refPPT = refPPT

        // Detect the shared seam once; both bars hug it (or center if not adjacent),
        // placed via the shared descriptor so there's no per-screen coordinate flip.
        let seam = SchematicLayout.seam(reference.bounds, target.bounds)
        let refIsA = seam.map { referenceIsA($0, reference.bounds) } ?? true
        let refAnchor = seam.map { BarPlacement(seam: $0, screen: reference.bounds, selfIsA: refIsA) }
        let targetAnchor = seam.map { BarPlacement(seam: $0, screen: target.bounds, selfIsA: !refIsA) }

        // Both bars are windows crossing the seam. They start at the full shared edge
        // (the overlap, in each screen's own points), as long as possible for accurate
        // matching; the user drags either to make them physically equal. The overlap is
        // the same point count on both screens; only its physical size differs.
        let overlapPoints = seam.map { $0.hi - $0.lo } ?? CGFloat(10.0 / 2.54 * refPPT)
        refLengthPoints = overlapPoints
        targetLengthPoints = overlapPoints

        // Both bars wear the same QuickTime-trimmer look; a small label tells them
        // apart. Reference bar (trusted screen): a pure resize affordance, no controls.
        let refView = BarView(length: overlapPoints, anchor: refAnchor, role: "Reference")
        refView.onResize = { [weak self] len in self?.refLengthPoints = len; self?.updateReadout() }
        refWindow = makeWindow(screen: refScreen, view: refView, interactive: true)

        // Target bar (target screen): also a pure resize affordance. The controls now
        // live in a floating panel, keeping the overlay clean.
        let calView = BarView(length: overlapPoints, anchor: targetAnchor, role: "This display")
        calView.onResize = { [weak self] len in self?.targetLengthPoints = len; self?.updateReadout() }
        targetWindow = makeWindow(screen: targetScreen, view: calView, interactive: true)

        // A native floating panel on the target screen holds the instruction, the live
        // inferred-size readout, and Save/Cancel — instead of controls floating on the dim.
        let panel = CalibrationPanel(displayName: target.name)
        panel.onSave = { [weak self] in self?.save() }
        panel.onCancel = { [weak self] in self?.cancel(); self?.onComplete?() }
        panel.present(on: targetScreen, near: targetAnchor)
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        updateReadout()
    }

    func cancel() {
        refWindow?.orderOut(nil); refWindow = nil
        targetWindow?.orderOut(nil); targetWindow = nil
        panel?.orderOut(nil); panel = nil
        target = nil
    }

    /// The target PPI implied by the two current bar lengths: the reference bar's
    /// known physical length (points ÷ trusted PPI) equals the target bar's.
    private func inferredTargetPPI() -> Double {
        let refInches = Double(refLengthPoints) / refPPT
        return refInches > 0 ? Double(targetLengthPoints) / refInches : 0
    }

    private func updateReadout() {
        guard let target else { return }
        let ppt = inferredTargetPPI()
        let diag = ppt > 0
            ? (Double(target.bounds.width) * Double(target.bounds.width)
               + Double(target.bounds.height) * Double(target.bounds.height)).squareRoot() / ppt
            : 0
        panel?.setInferredDiagonal(diag)
    }

    private func save() {
        let ppt = inferredTargetPPI()
        guard let target, ppt > 0 else { cancel(); onComplete?(); return }
        let inchesW = Double(target.bounds.width) / ppt
        let inchesH = Double(target.bounds.height) / ppt
        CalibrationStore.setOverride(CGSize(width: inchesW * 25.4, height: inchesH * 25.4),
                                     for: target.fingerprint)
        cancel()
        onComplete?()
    }

    // MARK: - Geometry

    /// Whether `bounds` is on the a-side of `seam` (left for a vertical seam, top
    /// for a horizontal one), matching `Seam`'s a = left/top convention.
    private func referenceIsA(_ seam: SchematicLayout.Seam, _ bounds: CGRect) -> Bool {
        seam.vertical ? abs(bounds.maxX - seam.line) < 1 : abs(bounds.maxY - seam.line) < 1
    }

    // MARK: - Window/screen helpers

    private func makeWindow(screen: NSScreen, view: NSView, interactive: Bool) -> NSWindow {
        let window = interactive
            ? KeyableBorderlessWindow(contentRect: screen.frame, styleMask: .borderless,
                                      backing: .buffered, defer: false)
            : NSWindow(contentRect: screen.frame, styleMask: .borderless,
                       backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Above the menu bar so a bar hugging the top edge is still grabbable.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.ignoresMouseEvents = !interactive
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        view.frame = CGRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first {
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id
        }
    }
}

/// Borderless windows can't become key by default, which would block the
/// Save/Cancel buttons. This subclass allows it.
final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The native control surface for match calibration: a small floating HUD panel
/// with a quiet instruction, a prominent live inferred-diagonal readout, and
/// Save/Cancel — instead of bare buttons floating on the dimmed overlay.
@MainActor
final class CalibrationPanel: NSPanel {
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    private let valueLabel = NSTextField(labelWithString: "—")
    private let displayName: String

    init(displayName: String) {
        self.displayName = displayName
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 214),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Above the shielding-level overlay windows so the panel stays reachable.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        buildContent()
    }

    override var canBecomeKey: Bool { true }

    private func buildContent() {
        let title = NSTextField(labelWithString: displayName)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center

        let instruction = NSTextField(wrappingLabelWithString:
            "Drag the bars until they look the same real size.")
        instruction.font = .systemFont(ofSize: 12)
        instruction.textColor = .secondaryLabelColor
        instruction.alignment = .center
        instruction.preferredMaxLayoutWidth = 260

        let caption = NSTextField(labelWithString: "INFERRED DIAGONAL")
        caption.font = .systemFont(ofSize: 10, weight: .semibold)
        caption.textColor = .tertiaryLabelColor
        caption.alignment = .center

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .center

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.controlSize = .large; cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.controlSize = .large; save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        // The modern prominent (accent-filled) default button.
        save.bezelColor = .controlAccentColor

        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually

        let stack = NSStackView(views: [title, instruction, caption, valueLabel, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        stack.setCustomSpacing(16, after: instruction)
        stack.setCustomSpacing(2, after: caption)
        stack.setCustomSpacing(18, after: valueLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // A modern rounded translucent card (popover material), not the dated HUD frame.
        let card = NSVisualEffectView()
        card.material = .popover
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            buttons.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        contentView = card
    }

    /// Show the panel on `screen`, near the target bar (`anchor`) but inset toward the
    /// screen's center so it doesn't cover the bar. Falls back to top-center when the
    /// bar isn't anchored to a seam.
    fileprivate func present(on screen: NSScreen, near anchor: BarPlacement?) {
        let vis = screen.visibleFrame
        let gap: CGFloat = 40
        var origin = NSPoint(x: vis.midX - frame.width / 2, y: vis.maxY - frame.height - 60)

        if let a = anchor {
            // `a.along` is the bar's center in the screen's local y-up frame; convert to
            // global. The bar hugs `a.edge` (inset by `barEdgeInset`); place the panel
            // just inward of it, aligned to the bar's midpoint.
            let f = screen.frame
            switch a.edge {
            case .right:
                let barX = f.maxX - barEdgeInset - BarView.thickness
                origin = NSPoint(x: barX - frame.width - gap, y: f.minY + a.along - frame.height / 2)
            case .left:
                let barX = f.minX + barEdgeInset + BarView.thickness
                origin = NSPoint(x: barX + gap, y: f.minY + a.along - frame.height / 2)
            case .top:
                let barY = f.maxY - barEdgeInset - BarView.thickness
                origin = NSPoint(x: f.minX + a.along - frame.width / 2, y: barY - frame.height - gap)
            case .bottom:
                let barY = f.minY + barEdgeInset + BarView.thickness
                origin = NSPoint(x: f.minX + a.along - frame.width / 2, y: barY + gap)
            }
        }

        // Keep the panel fully on the visible screen.
        origin.x = min(max(origin.x, vis.minX + 12), vis.maxX - frame.width - 12)
        origin.y = min(max(origin.y, vis.minY + 12), vis.maxY - frame.height - 12)
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
    }

    /// Update the prominent readout with the currently inferred diagonal in inches.
    func setInferredDiagonal(_ inches: Double) {
        valueLabel.stringValue = inches > 0 ? String(format: "%.1f″", inches) : "—"
    }

    @objc private func saveTapped() { onSave?() }
    @objc private func cancelTapped() { onCancel?() }
}

/// Distance the bar is inset from the screen edge it hugs, so it reads as a floating
/// control rather than something glued to the bezel.
private let barEdgeInset: CGFloat = 22

/// Rect for a bar of the given length, hugging an optional seam placement (or a
/// horizontal bar centered in `bounds` when there's no seam). `offset` slides the
/// bar's center along the seam from its anchor; `thickness` sets its cross size.
private func barRect(length: CGFloat, offset: CGFloat, thickness t: CGFloat,
                     anchor: BarPlacement?, in bounds: NSRect) -> NSRect {
    guard let a = anchor else {
        return NSRect(x: bounds.midX - length / 2, y: bounds.midY - t / 2, width: length, height: t)
    }
    let along = a.along + offset
    let inset = barEdgeInset
    switch a.edge {
    case .right:  return NSRect(x: bounds.maxX - t - inset, y: along - length / 2, width: t, height: length)
    case .left:   return NSRect(x: bounds.minX + inset,     y: along - length / 2, width: t, height: length)
    case .top:    return NSRect(x: along - length / 2, y: bounds.maxY - t - inset, width: length, height: t)
    case .bottom: return NSRect(x: along - length / 2, y: bounds.minY + inset,     width: length, height: t)
    }
}

/// A rounded orange bar hugging the seam, inset from the edge. Three circular
/// draggers — one at each end (resize, symmetric about the bar's center) and one at
/// the midpoint (slide the whole bar along the seam) — each with a perpendicular
/// guide line through it so the two bars can be sighted across the gap. Reports its
/// live length so the controller can infer the target's PPI. Purely an affordance —
/// the readout and Save/Cancel live in the floating panel.
private final class BarView: NSView {
    var onResize: ((CGFloat) -> Void)?

    private var length: CGFloat
    private var offset: CGFloat = 0        // slide of the bar's center along the seam
    private let anchor: BarPlacement?
    private let role: String
    private let roleLabel = NSTextField(labelWithString: "")

    private static let orange = NSColor.systemOrange
    /// Bar cross-thickness (thinner than before so it reads as a slim rounded bar).
    static let thickness: CGFloat = 14
    /// Radius of the circular draggers.
    private static let knob: CGFloat = 12
    /// How far the guide line extends past its dragger, on each side.
    private static let guideReach: CGFloat = 30

    init(length: CGFloat, anchor: BarPlacement?, role: String) {
        self.length = length; self.anchor = anchor; self.role = role
        super.init(frame: .zero)
        roleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        roleLabel.textColor = .white
        roleLabel.stringValue = role
        roleLabel.isBezeled = false; roleLabel.drawsBackground = false; roleLabel.isEditable = false
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1)
        roleLabel.shadow = shadow
        addSubview(roleLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var lengthIsVertical: Bool { anchor?.lengthIsVertical ?? false }

    /// The bar's anchored center along the seam (before `offset`).
    private func anchorAlong() -> CGFloat {
        if let a = anchor { return a.along }
        return lengthIsVertical ? bounds.midY : bounds.midX
    }

    private func rect() -> NSRect {
        barRect(length: length, offset: offset, thickness: Self.thickness, anchor: anchor, in: bounds)
    }

    /// Centers of the three draggers: [endA, midpoint, endB], along the bar's axis.
    private func knobCenters(_ r: NSRect) -> [CGPoint] {
        if lengthIsVertical {
            return [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.midY), CGPoint(x: r.midX, y: r.maxY)]
        }
        return [CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.midX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)]
    }

    // MARK: Mouse — end knobs resize; the midpoint knob slides the whole bar

    private enum Grab { case none, resize, move }
    private var grab: Grab = .none

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let c = knobCenters(rect())
        let hit = Self.knob + 6
        if hypot(p.x - c[1].x, p.y - c[1].y) <= hit {
            grab = .move
        } else if hypot(p.x - c[0].x, p.y - c[0].y) <= hit || hypot(p.x - c[2].x, p.y - c[2].y) <= hit {
            grab = .resize
        } else {
            grab = .none
        }
        if grab != .none { apply(p) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard grab != .none else { return }
        apply(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) { grab = .none }

    private func apply(_ p: CGPoint) {
        let coord = lengthIsVertical ? p.y : p.x
        let maxAlong = lengthIsVertical ? bounds.height : bounds.width
        let barCenter = anchorAlong() + offset
        switch grab {
        case .resize:
            // Symmetric about the bar's current center. Cap so both ends stay on screen.
            let half = min(abs(coord - barCenter),
                           min(barCenter, maxAlong - barCenter))
            length = max(Self.knob * 3, 2 * half)
        case .move:
            // Slide the whole bar; keep both ends on screen.
            let clamped = min(maxAlong - length / 2, max(length / 2, coord))
            offset = clamped - anchorAlong()
        case .none:
            break
        }
        onResize?(length)
        needsDisplay = true
    }

    // MARK: Cursor

    override func resetCursorRects() {
        let resize: NSCursor = lengthIsVertical ? .resizeUpDown : .resizeLeftRight
        let c = knobCenters(rect())
        let box = Self.knob + 6
        func square(_ p: CGPoint) -> NSRect { NSRect(x: p.x - box, y: p.y - box, width: 2 * box, height: 2 * box) }
        addCursorRect(square(c[0]), cursor: resize)
        addCursorRect(square(c[2]), cursor: resize)
        addCursorRect(square(c[1]), cursor: .openHand)
    }

    // MARK: Draw

    override func draw(_ dirtyRect: NSRect) {
        // A soft scrim on both screens so the orange control reads cleanly over content.
        NSColor.black.withAlphaComponent(0.12).setFill(); bounds.fill()

        let r = rect()
        let centers = knobCenters(r)

        drawGuides(centers)
        drawBar(r)
        for c in centers { drawKnob(at: c) }
        layoutRoleLabel(r)
    }

    /// The bar itself: a fully-rounded (capsule) orange bar, slightly translucent.
    private func drawBar(_ r: NSRect) {
        let radius = Self.thickness / 2
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        Self.orange.withAlphaComponent(0.9).setFill(); path.fill()
    }

    /// A white circle ringed in orange at each dragger position.
    private func drawKnob(at c: CGPoint) {
        let r = Self.knob
        let circle = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        NSColor.white.setFill(); circle.fill()
        Self.orange.setStroke(); circle.lineWidth = 3; circle.stroke()
    }

    /// A short guide line through each dragger, perpendicular to the bar, so the two
    /// bars can be lined up across the gap.
    private func drawGuides(_ centers: [CGPoint]) {
        let g = Self.guideReach
        let path = NSBezierPath()
        func clamp(_ v: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, 1), hi - 1) }
        for c in centers {
            if lengthIsVertical {                   // bar vertical; guide is horizontal
                let y = clamp(c.y, bounds.maxY)
                let x0 = max(0, c.x - Self.thickness / 2 - g)
                let x1 = min(bounds.maxX, c.x + Self.thickness / 2 + g)
                path.move(to: CGPoint(x: x0, y: y)); path.line(to: CGPoint(x: x1, y: y))
            } else {                                // bar horizontal; guide is vertical
                let x = clamp(c.x, bounds.maxX)
                let y0 = max(0, c.y - Self.thickness / 2 - g)
                let y1 = min(bounds.maxY, c.y + Self.thickness / 2 + g)
                path.move(to: CGPoint(x: x, y: y0)); path.line(to: CGPoint(x: x, y: y1))
            }
        }
        Self.orange.withAlphaComponent(0.7).setStroke(); path.lineWidth = 1.5; path.stroke()
    }

    /// The role label ("Reference" / "This display") tucked just outside the bar,
    /// so the two identical-looking bars can be told apart.
    private func layoutRoleLabel(_ r: NSRect) {
        roleLabel.sizeToFit()
        let s = roleLabel.frame.size
        let pad = Self.guideReach + 10
        let origin: CGPoint
        switch anchor?.edge {
        case .right:  origin = CGPoint(x: r.minX - s.width - pad, y: r.midY - s.height / 2)
        case .left:   origin = CGPoint(x: r.maxX + pad,           y: r.midY - s.height / 2)
        case .top:    origin = CGPoint(x: r.midX - s.width / 2,   y: r.minY - s.height - pad)
        case .bottom: origin = CGPoint(x: r.midX - s.width / 2,   y: r.maxY + pad)
        case .none:   origin = CGPoint(x: r.midX - s.width / 2,   y: r.maxY + pad)
        }
        roleLabel.frame = NSRect(origin: origin, size: s)
    }
}
