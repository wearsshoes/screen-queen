import AppKit

/// Where a calibration bar sits relative to the seam it should hug, expressed in
/// the local (y-up) coordinates of the screen it's drawn on.
fileprivate struct SeamAnchor {
    enum Edge { case left, right, top, bottom } // which edge of this view the bar abuts
    let edge: Edge
    let along: CGFloat   // center position along the seam: a y for left/right, an x for top/bottom

    /// The bar runs parallel to the seam, so its length axis is vertical for a
    /// vertical seam (left/right edges) and horizontal for a horizontal seam.
    var lengthIsVertical: Bool { edge == .left || edge == .right }
}

private let barThickness: CGFloat = 28

/// Visual "match the bars" calibration. Because pixels are square, PPI is the
/// same in both axes, so a single length suffices — no need for a 2D box.
///
/// A known-physical-length bar is shown on a trusted reference display (the
/// built-in, whose EDID we believe); a resizable bar is shown on the target.
/// The user matches their lengths, and we infer the target's points-per-inch:
///
///   pointsPerInch_target = matchedLengthInPoints / referenceInches
///
/// Both bars run parallel to the shared seam, centered on the overlap midpoint,
/// so they sit directly across the gap for an easy side-by-side comparison.
@MainActor
final class CalibrationController {

    /// Physical length of the reference bar, in inches. Defaults to 10 cm but is
    /// capped to the seam overlap so the bar never spills past the shared edge.
    private var referenceInches: Double = 10.0 / 2.54

    private var refWindow: NSWindow?
    private var targetWindow: NSWindow?
    private var target: DisplaySnapshot?

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

        // Hug the seam if the two displays are adjacent; otherwise center.
        let refAnchor = seamAnchor(selfBounds: reference.bounds, otherBounds: target.bounds)
        let targetAnchor = seamAnchor(selfBounds: target.bounds, otherBounds: reference.bounds)

        // Cap the reference length to fit within the seam overlap (on the
        // reference screen), so the bar stays inside the shared edge.
        let defaultInches = 10.0 / 2.54
        referenceInches = defaultInches
        if let overlap = seamOverlapPoints(reference.bounds, target.bounds) {
            let overlapInches = Double(overlap) / refPPT
            referenceInches = min(defaultInches, max(0.5, overlapInches * 0.9))
        }

        // Reference bar: a fixed physical length rendered on the trusted screen.
        let refLength = CGFloat(referenceInches * refPPT)
        let refView = BarView(length: refLength, color: .systemGreen, anchor: refAnchor,
                              caption: String(format: "Reference: %.1f cm", referenceInches * 2.54))
        refWindow = makeWindow(screen: refScreen, view: refView, interactive: false)

        // Target bar: resizable; starts near the (untrusted) EDID guess.
        let startLength = CGFloat((target.pointsPerInch ?? 100) * referenceInches)
        let calView = CalibrationView(length: startLength,
                                      referenceInches: referenceInches,
                                      targetPointSize: target.bounds.size,
                                      displayName: target.name,
                                      anchor: targetAnchor)
        calView.onSave = { [weak self] length in self?.save(length: length) }
        calView.onCancel = { [weak self] in self?.cancel(); self?.onComplete?() }
        targetWindow = makeWindow(screen: targetScreen, view: calView, interactive: true)
        targetWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancel() {
        refWindow?.orderOut(nil); refWindow = nil
        targetWindow?.orderOut(nil); targetWindow = nil
        target = nil
    }

    private func save(length: CGFloat) {
        guard let target, length > 0 else { cancel(); onComplete?(); return }
        let ppt = Double(length) / referenceInches
        let inchesW = Double(target.bounds.width) / ppt
        let inchesH = Double(target.bounds.height) / ppt
        CalibrationStore.setOverride(CGSize(width: inchesW * 25.4, height: inchesH * 25.4),
                                     for: target.fingerprint)
        cancel()
        onComplete?()
    }

    // MARK: - Geometry

    /// Anchor for a bar drawn on `selfBounds` hugging the seam it shares with
    /// `otherBounds`. Returns nil when the two displays aren't adjacent.
    /// Coordinates are in the self-screen's local y-up space.
    private func seamAnchor(selfBounds A: CGRect, otherBounds B: CGRect) -> SeamAnchor? {
        let tol: CGFloat = 2

        // Vertical seam (side by side).
        if abs(A.maxX - B.minX) <= tol {          // self is left → abut right edge
            let top = max(A.minY, B.minY), bot = min(A.maxY, B.maxY)
            if bot - top > tol {
                return SeamAnchor(edge: .right, along: A.height - ((top + bot) / 2 - A.minY))
            }
        }
        if abs(B.maxX - A.minX) <= tol {          // self is right → abut left edge
            let top = max(A.minY, B.minY), bot = min(A.maxY, B.maxY)
            if bot - top > tol {
                return SeamAnchor(edge: .left, along: A.height - ((top + bot) / 2 - A.minY))
            }
        }
        // Horizontal seam (stacked). CG is y-down, so A.maxY == B.minY ⇒ A is on top.
        if abs(A.maxY - B.minY) <= tol {          // self is top → abut bottom edge (y-up = 0)
            let l = max(A.minX, B.minX), r = min(A.maxX, B.maxX)
            if r - l > tol {
                return SeamAnchor(edge: .bottom, along: (l + r) / 2 - A.minX)
            }
        }
        if abs(B.maxY - A.minY) <= tol {          // self is bottom → abut top edge (y-up = height)
            let l = max(A.minX, B.minX), r = min(A.maxX, B.maxX)
            if r - l > tol {
                return SeamAnchor(edge: .top, along: (l + r) / 2 - A.minX)
            }
        }
        return nil
    }

    /// Length (in global points) of the overlap segment shared by two adjacent
    /// displays, or nil if they aren't adjacent.
    private func seamOverlapPoints(_ A: CGRect, _ B: CGRect) -> CGFloat? {
        let tol: CGFloat = 2
        if abs(A.maxX - B.minX) <= tol || abs(B.maxX - A.minX) <= tol {
            let o = min(A.maxY, B.maxY) - max(A.minY, B.minY)
            return o > tol ? o : nil
        }
        if abs(A.maxY - B.minY) <= tol || abs(B.maxY - A.minY) <= tol {
            let o = min(A.maxX, B.maxX) - max(A.minX, B.minX)
            return o > tol ? o : nil
        }
        return nil
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
        window.level = .floating
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

/// Rect for a bar of the given length, hugging an optional seam anchor (or a
/// horizontal bar centered in `bounds` when there's no anchor).
private func barRect(length: CGFloat, anchor: SeamAnchor?, in bounds: NSRect) -> NSRect {
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

/// A static bar of a fixed point length, with a caption.
private final class BarView: NSView {
    private let length: CGFloat
    private let color: NSColor
    private let anchor: SeamAnchor?
    private let caption: String

    init(length: CGFloat, color: NSColor, anchor: SeamAnchor?, caption: String) {
        self.length = length; self.color = color; self.anchor = anchor; self.caption = caption
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = barRect(length: length, anchor: anchor, in: bounds)
        color.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: color
        ]
        let size = (caption as NSString).size(withAttributes: attrs)
        let y = min(rect.maxY + 8, bounds.maxY - size.height - 4)
        (caption as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: y), withAttributes: attrs)
    }
}

/// Interactive resizable bar anchored to the seam; drag along the seam to change
/// its length (centered on the overlap midpoint). Shows the live inferred diagonal.
private final class CalibrationView: NSView {
    var onSave: ((CGFloat) -> Void)?
    var onCancel: (() -> Void)?

    private var length: CGFloat
    private let referenceInches: Double
    private let targetPointSize: CGSize
    private let displayName: String
    private let anchor: SeamAnchor?

    private var readout: NSTextField!

    init(length: CGFloat, referenceInches: Double, targetPointSize: CGSize,
         displayName: String, anchor: SeamAnchor?) {
        self.length = length
        self.referenceInches = referenceInches
        self.targetPointSize = targetPointSize
        self.displayName = displayName
        self.anchor = anchor
        super.init(frame: .zero)
        setupControls()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var lengthIsVertical: Bool { anchor?.lengthIsVertical ?? false }

    private func center() -> CGFloat {
        if let a = anchor { return a.along }
        return lengthIsVertical ? bounds.midY : bounds.midX
    }

    // MARK: Controls

    private func setupControls() {
        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"

        readout = NSTextField(labelWithString: "")
        readout.font = .boldSystemFont(ofSize: 14)
        readout.textColor = .systemOrange
        readout.alignment = .center

        for v in [save, cancel, readout!] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            readout.centerXAnchor.constraint(equalTo: centerXAnchor),
            readout.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            save.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -60),
            save.trailingAnchor.constraint(equalTo: centerXAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            cancel.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 8),
        ])
        updateReadout()
    }

    private func updateReadout() {
        let ppt = Double(length) / referenceInches
        let diag = ppt > 0
            ? (Double(targetPointSize.width) * Double(targetPointSize.width)
               + Double(targetPointSize.height) * Double(targetPointSize.height)).squareRoot() / ppt
            : 0
        readout.stringValue = String(format: "%@ — drag the bar to match the green one, then Save · inferred ≈ %.1f″",
                                     displayName, diag)
    }

    // MARK: Mouse — drag along the seam to resize (symmetric about the midpoint)

    override func mouseDown(with event: NSEvent) { resize(to: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { resize(to: convert(event.locationInWindow, from: nil)) }

    private func resize(to p: CGPoint) {
        let coord = lengthIsVertical ? p.y : p.x
        let maxLen = lengthIsVertical ? bounds.height : bounds.width
        length = min(maxLen, max(20, 2 * abs(coord - center())))
        updateReadout()
        needsDisplay = true
    }

    @objc private func saveTapped() { onSave?(length) }
    @objc private func cancelTapped() { onCancel?() }

    // MARK: Draw

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()

        let rect = barRect(length: length, anchor: anchor, in: bounds)
        NSColor.systemOrange.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

        // End caps as drag hints.
        NSColor.white.setStroke()
        let cap = NSBezierPath()
        if lengthIsVertical {
            cap.move(to: CGPoint(x: rect.minX + 6, y: rect.minY)); cap.line(to: CGPoint(x: rect.maxX - 6, y: rect.minY))
            cap.move(to: CGPoint(x: rect.minX + 6, y: rect.maxY)); cap.line(to: CGPoint(x: rect.maxX - 6, y: rect.maxY))
        } else {
            cap.move(to: CGPoint(x: rect.minX, y: rect.minY + 6)); cap.line(to: CGPoint(x: rect.minX, y: rect.maxY - 6))
            cap.move(to: CGPoint(x: rect.maxX, y: rect.minY + 6)); cap.line(to: CGPoint(x: rect.maxX, y: rect.maxY - 6))
        }
        cap.lineWidth = 2; cap.stroke()
    }
}
