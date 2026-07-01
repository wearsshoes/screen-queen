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
    private var controlsBar: BarView?
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

        // Reference bar (trusted screen): resizable, no controls.
        let refView = BarView(length: overlapPoints, color: .systemGreen, anchor: refAnchor, controls: false)
        refView.onResize = { [weak self] len in self?.refLengthPoints = len; self?.updateReadout() }
        refWindow = makeWindow(screen: refScreen, view: refView, interactive: true)

        // Target bar (target screen): resizable, hosts the readout + Save/Cancel.
        let calView = BarView(length: overlapPoints, color: .systemOrange, anchor: targetAnchor, controls: true)
        calView.onResize = { [weak self] len in self?.targetLengthPoints = len; self?.updateReadout() }
        calView.onSave = { [weak self] in self?.save() }
        calView.onCancel = { [weak self] in self?.cancel(); self?.onComplete?() }
        controlsBar = calView
        targetWindow = makeWindow(screen: targetScreen, view: calView, interactive: true)
        targetWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateReadout()
    }

    func cancel() {
        refWindow?.orderOut(nil); refWindow = nil
        targetWindow?.orderOut(nil); targetWindow = nil
        controlsBar = nil
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
        controlsBar?.setReadout(String(format: "%@ — drag either bar so they're the same real length, then Save · inferred ≈ %.1f″",
                                       target.name, diag))
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

/// Rect for a bar of the given length, hugging an optional seam placement (or a
/// horizontal bar centered in `bounds` when there's no seam).
private func barRect(length: CGFloat, anchor: BarPlacement?, in bounds: NSRect) -> NSRect {
    let t = barThickness
    guard let a = anchor else {
        return NSRect(x: bounds.midX - length / 2, y: bounds.midY - t / 2, width: length, height: t)
    }
    switch a.edge {
    case .right:  return NSRect(x: bounds.maxX - t, y: a.along - length / 2, width: t, height: length)
    case .left:   return NSRect(x: bounds.minX,     y: a.along - length / 2, width: t, height: length)
    case .top:    return NSRect(x: a.along - length / 2, y: bounds.maxY - t, width: length, height: t)
    case .bottom: return NSRect(x: a.along - length / 2, y: bounds.minY,     width: length, height: t)
    }
}

/// A resizable bar hugging the seam: drag along the seam to change its length
/// (symmetric about the overlap midpoint). Reports its live length so the
/// controller can compare the two bars and infer the target's PPI; the `controls`
/// bar also hosts the readout + Save/Cancel.
private final class BarView: NSView {
    var onResize: ((CGFloat) -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    private var length: CGFloat
    private let color: NSColor
    private let anchor: BarPlacement?
    private var readout: NSTextField?

    init(length: CGFloat, color: NSColor, anchor: BarPlacement?, controls: Bool) {
        self.length = length; self.color = color; self.anchor = anchor
        super.init(frame: .zero)
        if controls { setupControls() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var lengthIsVertical: Bool { anchor?.lengthIsVertical ?? false }

    private func center() -> CGFloat {
        if let a = anchor { return a.along }
        return lengthIsVertical ? bounds.midY : bounds.midX
    }

    /// Set the readout text; the controller computes it from both bars' lengths.
    func setReadout(_ text: String) { readout?.stringValue = text }

    // MARK: Controls

    private func setupControls() {
        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"

        let label = NSTextField(labelWithString: "")
        label.font = .boldSystemFont(ofSize: 14)
        label.textColor = .systemOrange
        label.alignment = .center
        readout = label

        for v in [save, cancel, label] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            save.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -60),
            save.trailingAnchor.constraint(equalTo: centerXAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            cancel.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 8),
        ])
    }

    // MARK: Mouse — drag along the seam to resize (symmetric about the midpoint)

    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Start a drag only from on/near the bar or its handles — so clicks elsewhere
        // don't yank the bar to the cursor.
        dragging = nearBar(p)
        if dragging { resize(to: p) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        resize(to: convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) { dragging = false }

    /// Whether `p` is within the grabbable zone: the bar plus a margin inward from
    /// each end (where the handles sit), across the bar's thickness.
    private func nearBar(_ p: CGPoint) -> Bool {
        let rect = barRect(length: length, anchor: anchor, in: bounds).insetBy(dx: -Self.handleRadius, dy: -Self.handleRadius)
        return rect.contains(p)
    }

    private func resize(to p: CGPoint) {
        let coord = lengthIsVertical ? p.y : p.x
        let maxLen = lengthIsVertical ? bounds.height : bounds.width
        length = min(maxLen, max(20, 2 * abs(coord - center())))
        onResize?(length)
        needsDisplay = true
    }

    @objc private func saveTapped() { onSave?() }
    @objc private func cancelTapped() { onCancel?() }

    // MARK: Draw

    override func draw(_ dirtyRect: NSRect) {
        // Faint dim on both screens so the thin guidelines stay legible over content.
        NSColor.black.withAlphaComponent(0.18).setFill(); bounds.fill()

        let rect = barRect(length: length, anchor: anchor, in: bounds)

        drawCrosshairs(rect)

        color.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

        for c in handleCenters(rect) { drawHandle(at: c) }
    }

    /// A grab handle inset from each end of the bar, so the draggable spot is obvious
    /// and reachable even when the bar spans the whole screen (ends in the corners).
    private static let handleInset: CGFloat = 26
    private static let handleRadius: CGFloat = 13

    private func handleCenters(_ rect: NSRect) -> [CGPoint] {
        let inset = min(Self.handleInset, (lengthIsVertical ? rect.height : rect.width) / 2 - 2)
        if lengthIsVertical {
            return [CGPoint(x: rect.midX, y: rect.minY + inset), CGPoint(x: rect.midX, y: rect.maxY - inset)]
        }
        return [CGPoint(x: rect.minX + inset, y: rect.midY), CGPoint(x: rect.maxX - inset, y: rect.midY)]
    }

    private func drawHandle(at c: CGPoint) {
        let r = Self.handleRadius
        let circle = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        NSColor.white.withAlphaComponent(0.95).setFill(); circle.fill()
        color.setStroke(); circle.lineWidth = 2; circle.stroke()
        // Grip dots so it reads as a handle.
        color.setFill()
        for d: CGFloat in [-4, 0, 4] {
            let dot = lengthIsVertical
                ? NSRect(x: c.x + d - 1, y: c.y - 1, width: 2, height: 2)
                : NSRect(x: c.x - 1, y: c.y + d - 1, width: 2, height: 2)
            NSBezierPath(ovalIn: dot).fill()
        }
    }

    /// Three full-screen lines perpendicular to the seam — through the bar's two ends
    /// and its midpoint — so each can be sighted straight across the gap onto the
    /// other screen's lines. Drawn as a 1px black core outlined in red for visibility.
    private func drawCrosshairs(_ rect: NSRect) {
        let path = NSBezierPath()
        // Nudge lines 1px inside the screen edge so a full-length bar's end lines
        // aren't clipped to an invisible hairline.
        func clamp(_ v: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, 1), hi - 1) }
        if lengthIsVertical {                       // bar runs vertically; lines are horizontal
            for y in [rect.minY, rect.midY, rect.maxY] {
                let y = clamp(y, bounds.maxY)
                path.move(to: CGPoint(x: 0, y: y)); path.line(to: CGPoint(x: bounds.maxX, y: y))
            }
        } else {                                    // bar runs horizontally; lines are vertical
            for x in [rect.minX, rect.midX, rect.maxX] {
                let x = clamp(x, bounds.maxX)
                path.move(to: CGPoint(x: x, y: 0)); path.line(to: CGPoint(x: x, y: bounds.maxY))
            }
        }
        NSColor.red.setStroke(); path.lineWidth = 3; path.stroke()      // red outline
        NSColor.black.setStroke(); path.lineWidth = 1; path.stroke()    // black core
    }
}
