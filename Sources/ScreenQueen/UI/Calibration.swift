import AppKit

/// Visual "match the tapes" calibration.
///
/// Each display wears two tapes: one along its edge nearest the other display
/// (spanning the full edge — the seam picks the edge but doesn't cap the tape),
/// and one along a perpendicular edge — the bottom, except a built-in laptop
/// panel uses its top, since the laptop sits on the desk with its screen below
/// the monitor's. The two pairs are matched independently, one per axis: the
/// primary pair sizes one dimension, the perpendicular pair the other — she
/// doesn't assume square pixels, she checks. (Rotated screens would swap her
/// axes, but the user should know better than to flip their screen.) The
/// reference display is trusted (its EDID PPI), so each of its tapes' physical
/// length (points ÷ refPPI) is known; at a match, per axis:
///
///   pointsPerInch_target = targetTapePoints / (refTapePoints / refPPI)
///
/// ⏎ saves and ⎋ cancels from anywhere — the panel or either tape.
@MainActor
final class CalibrationController {

    private var refWindow: NSWindow?
    private var targetWindow: NSWindow?
    private var panel: CalibrationPanel?
    private var target: DisplaySnapshot?
    private weak var targetBar: BarView?   // for arrow-key nudges routed via the panel
    private var keyObservers: [NSObjectProtocol] = []   // panel key-status → tape glow

    private var refPPT: Double = 0             // trusted reference PPI (source of truth)
    // Live tape lengths, one per axis per screen: the primary pair (seam-facing
    // edges) measures one axis, the perpendicular pair the other.
    private var refPrimaryLen: CGFloat = 0
    private var refPerpLen: CGFloat = 0
    private var targetPrimaryLen: CGFloat = 0
    private var targetPerpLen: CGFloat = 0
    /// Whether the primary pair runs vertically (side-by-side displays) — it then
    /// measures the y axis and the perpendicular pair the x axis; else swapped.
    private var primaryIsVertical = true

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

        // The seam picks each screen's *edge* facing the other display; it no longer
        // caps the tape, which spans that full edge. Without a seam (non-adjacent),
        // fall back to the perpendicular-edge convention for the primary too.
        let seam = SchematicLayout.seam(reference.bounds, target.bounds)
        let refIsA = seam.map { CalibrationMath.referenceIsA($0, reference.bounds) } ?? true
        let refEdge = seam.map { BarPlacement(seam: $0, screen: reference.bounds, selfIsA: refIsA).edge }
            ?? deskEdge(for: reference)
        let targetEdge = seam.map { BarPlacement(seam: $0, screen: target.bounds, selfIsA: !refIsA).edge }
            ?? deskEdge(for: target)

        // Two tapes per screen: the seam-facing edge, plus a perpendicular one —
        // the bottom by convention, except a laptop panel uses its top (the laptop
        // is on the desk; its top edge is the one near the monitor's bottom). Each
        // pair is an independent axis measurement.
        let (refPlace, refFull) = fullEdgePlacement(refEdge, on: refScreen)
        let (refPerpPlace, refPerpFull) = fullEdgePlacement(perpendicularEdge(to: refEdge, for: reference), on: refScreen)
        let (targetPlace, targetFull) = fullEdgePlacement(targetEdge, on: targetScreen)
        let (targetPerpPlace, targetPerpFull) = fullEdgePlacement(perpendicularEdge(to: targetEdge, for: target), on: targetScreen)
        refPrimaryLen = refFull
        refPerpLen = refPerpFull
        targetPrimaryLen = targetFull
        targetPerpLen = targetPerpFull
        primaryIsVertical = targetPlace.lengthIsVertical

        // Both tapes wear the same look; the unit printed on the blade — "inches"
        // vs her "inches" — is what tells them apart. Reference tapes (trusted
        // screen): pure measuring affordances, no controls.
        let refView = BarView(length: refFull, anchor: refPlace,
                              pointsPerInch: refPPT, unitLabel: Copy.matchUnitReference,
                              brand: Copy.matchTapeBrandReference, finePrint: Copy.matchTapeFinePrintReference,
                              palette: .honest)
        let refPerpView = BarView(length: refPerpFull, anchor: refPerpPlace,
                                  pointsPerInch: refPPT, unitLabel: Copy.matchUnitReference,
                                  brand: Copy.matchTapeBrandReference, finePrint: Copy.matchTapeFinePrintReference,
                                  palette: .honest)
        refView.onResize = { [weak self] len in self?.refPrimaryLen = len; self?.updateReadout() }
        refPerpView.onResize = { [weak self] len in self?.refPerpLen = len; self?.updateReadout() }
        refWindow = makeWindow(screen: refScreen, views: [refView, refPerpView], interactive: true)

        // Target tapes (target screen). Their ribbons are ruled at the pitch the
        // display *claims* over EDID — even when a previous calibration knows
        // better — so when the two sides physically match, hers reads a different
        // number than the honest one. The lie, printed on the tape. (The ruling is
        // purely cosmetic; the actual inference below uses point lengths against
        // the reference's trusted PPI.)
        let targetPPI = target.edidPointsPerInch ?? refPPT
        let calView = BarView(length: targetFull, anchor: targetPlace,
                              pointsPerInch: targetPPI, unitLabel: Copy.matchUnitTarget,
                              brand: Copy.matchTapeBrandTarget, finePrint: Copy.matchTapeFinePrintTarget,
                              palette: .vanity)
        let calPerpView = BarView(length: targetPerpFull, anchor: targetPerpPlace,
                                  pointsPerInch: targetPPI, unitLabel: Copy.matchUnitTarget,
                                  brand: Copy.matchTapeBrandTarget, finePrint: Copy.matchTapeFinePrintTarget,
                                  palette: .vanity)
        calView.onResize = { [weak self] len in self?.targetPrimaryLen = len; self?.updateReadout() }
        calPerpView.onResize = { [weak self] len in self?.targetPerpLen = len; self?.updateReadout() }
        targetWindow = makeWindow(screen: targetScreen, views: [calView, calPerpView], interactive: true)
        targetBar = calView

        // ⏎ / ⎋ work from any tape, not just while the panel is key.
        for tape in [refView, refPerpView, calView, calPerpView] {
            tape.onCommit = { [weak self] in self?.save() }
            tape.onCancel = { [weak self] in self?.cancel(); self?.onComplete?() }
        }

        // A native floating panel on the target screen holds the instruction, the live
        // inferred-size readout, and Save/Cancel — instead of controls floating on the dim.
        let panel = CalibrationPanel(displayName: target.name, claimedInches: target.edidDiagonalInches)
        panel.onSave = { [weak self] in self?.save() }
        panel.onCancel = { [weak self] in self?.cancel(); self?.onComplete?() }
        panel.onNudge = { [weak self] delta in self?.targetBar?.nudge(delta) }
        panel.present(on: targetScreen, near: targetPlace)
        self.panel = panel

        // The panel opens key with its arrows routed to the liar's tape; keep her
        // active-tip glow in sync as key focus moves between panel and tapes.
        calView.externallyActive = true
        let nc = NotificationCenter.default
        keyObservers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel,
                                           queue: .main) { [weak calView] _ in
            MainActor.assumeIsolated { calView?.externallyActive = true }
        })
        keyObservers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                           queue: .main) { [weak calView] _ in
            MainActor.assumeIsolated { calView?.externallyActive = false }
        })

        NSApp.activate(ignoringOtherApps: true)
        updateReadout()
    }

    func cancel() {
        keyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyObservers.removeAll()
        refWindow?.orderOut(nil); refWindow = nil
        targetWindow?.orderOut(nil); targetWindow = nil
        panel?.orderOut(nil); panel = nil
        target = nil
    }

    /// The target's physical size in inches, one axis per tape pair: the primary
    /// pair sizes the axis it runs along, the perpendicular pair the other. `nil`
    /// until both axes are determined.
    private func inferredSizeInches() -> CGSize? {
        guard let target else { return nil }
        let ppiPrimary = CalibrationMath.inferredTargetPPI(refLengthPoints: refPrimaryLen, refPPI: refPPT,
                                                           targetLengthPoints: targetPrimaryLen)
        let ppiPerp = CalibrationMath.inferredTargetPPI(refLengthPoints: refPerpLen, refPPI: refPPT,
                                                        targetLengthPoints: targetPerpLen)
        guard ppiPrimary > 0, ppiPerp > 0 else { return nil }
        let ppiX = primaryIsVertical ? ppiPerp : ppiPrimary
        let ppiY = primaryIsVertical ? ppiPrimary : ppiPerp
        return CGSize(width: Double(target.bounds.width) / ppiX,
                      height: Double(target.bounds.height) / ppiY)
    }

    private func updateReadout() {
        let diag = inferredSizeInches().map { hypot(Double($0.width), Double($0.height)) } ?? 0
        panel?.setInferredDiagonal(diag)
    }

    private func save() {
        guard let target, let size = inferredSizeInches() else { cancel(); onComplete?(); return }
        CalibrationStore.setOverride(CGSize(width: size.width * 25.4, height: size.height * 25.4),
                                     for: target.fingerprint)
        cancel()
        onComplete?()
    }

    // MARK: - Placement helpers

    /// The perpendicular-tape edge for a display that isn't constrained by a seam:
    /// the bottom by convention, but a built-in laptop panel uses its top — the
    /// laptop is on the desk, so its top edge is the one living near the monitor.
    private func deskEdge(for d: DisplaySnapshot) -> BarPlacement.Edge {
        d.isBuiltin ? .top : .bottom
    }

    /// The edge for a display's second tape, perpendicular to its primary. For a
    /// vertical primary (side-by-side displays) that's the desk convention above;
    /// for a horizontal primary (stacked displays) both screens use the left edge
    /// so the pair can still be sighted across the gap.
    private func perpendicularEdge(to primary: BarPlacement.Edge, for d: DisplaySnapshot) -> BarPlacement.Edge {
        switch primary {
        case .left, .right: return deskEdge(for: d)
        case .top, .bottom: return .left
        }
    }

    /// A placement hugging `edge` and centered on it, plus that edge's full extent
    /// in the screen's points — the tape's starting length.
    private func fullEdgePlacement(_ edge: BarPlacement.Edge, on screen: NSScreen) -> (BarPlacement, CGFloat) {
        let size = screen.frame.size
        let vertical = edge == .left || edge == .right
        let extent = vertical ? size.height : size.width
        return (BarPlacement(edge: edge, along: extent / 2), extent)
    }

    // MARK: - Window/screen helpers

    private func makeWindow(screen: NSScreen, views: [NSView], interactive: Bool) -> NSWindow {
        let window = interactive
            ? KeyableBorderlessWindow(contentRect: screen.frame, styleMask: .borderless,
                                      backing: .buffered, defer: false)
            : NSWindow(contentRect: screen.frame, styleMask: .borderless,
                       backing: .buffered, defer: false)
        window.isOpaque = false
        // The soft scrim lives on the window so the tapes stacked in it don't
        // each darken the screen again.
        window.backgroundColor = NSColor.black.withAlphaComponent(0.12)
        window.hasShadow = false
        // Above the menu bar so a bar hugging the top edge is still grabbable.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.ignoresMouseEvents = !interactive
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        let container = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        for view in views {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        window.contentView = container
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
    /// Arrow-key fine adjustment, forwarded to the target tape (± points, ⇧ = ×10).
    var onNudge: ((CGFloat) -> Void)?

    private let valueLabel = NSTextField(labelWithString: Copy.matchReadoutPlaceholder)
    private let displayName: String
    private let claimedInches: Double

    init(displayName: String, claimedInches: Double) {
        self.displayName = displayName
        self.claimedInches = claimedInches
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

    /// Arrow keys nudge the target tape without stealing Save (⏎) or Cancel (⎋).
    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 124, 126: onNudge?(step)     // → / ↑
        case 123, 125: onNudge?(-step)    // ← / ↓
        default: super.keyDown(with: event)
        }
    }

    private func buildContent() {
        let title = NSTextField(labelWithString: displayName)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center

        let instruction = NSTextField(wrappingLabelWithString:
            Copy.matchInstruction)
        instruction.font = .systemFont(ofSize: 12)
        instruction.textColor = .secondaryLabelColor
        instruction.alignment = .center
        instruction.preferredMaxLayoutWidth = 260

        let caption = NSTextField(labelWithString: Copy.matchReadoutCaption)
        caption.font = .systemFont(ofSize: 10, weight: .semibold)
        caption.textColor = .tertiaryLabelColor
        caption.alignment = .center

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .center

        // What the monitor itself claims, for contrast with the live measurement.
        let claim = NSTextField(labelWithString:
            claimedInches > 0 ? Copy.matchClaimLine(String(format: "%.1f", claimedInches)) : "")
        claim.font = .systemFont(ofSize: 11)
        claim.textColor = .tertiaryLabelColor
        claim.alignment = .center
        claim.isHidden = claimedInches <= 0

        let cancel = NSButton(title: Copy.cancel, target: self, action: #selector(cancelTapped))
        cancel.controlSize = .large; cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: Copy.save, target: self, action: #selector(saveTapped))
        save.controlSize = .large; save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        // The modern prominent (accent-filled) default button.
        save.bezelColor = .controlAccentColor

        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually

        let stack = NSStackView(views: [title, instruction, caption, valueLabel, claim, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        stack.setCustomSpacing(16, after: instruction)
        stack.setCustomSpacing(2, after: caption)
        stack.setCustomSpacing(2, after: valueLabel)
        stack.setCustomSpacing(18, after: claim)
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
        setContentSize(card.fittingSize)   // the claim line made the fixed rect a lie
    }

    /// Show the panel on `screen`, near the target bar (`anchor`) but inset toward the
    /// screen's center so it doesn't cover the bar. Falls back to top-center when the
    /// bar isn't anchored to a seam.
    fileprivate func present(on screen: NSScreen, near anchor: BarPlacement?) {
        let vis = screen.visibleFrame
        let gap: CGFloat = 40
        var origin = NSPoint(x: vis.midX - frame.width / 2, y: vis.maxY - frame.height - 60)

        if let a = anchor {
            // `a.along` is the bar's center in the screen's local frame; convert to global.
            // The bar hugs `a.edge` (inset from it); place the panel just inward of the bar,
            // aligned to its midpoint.
            let f = screen.frame
            switch a.edge {
            case .right:
                let barX = f.maxX - CalibrationMath.barEdgeInset - BarView.thickness
                origin = NSPoint(x: barX - frame.width - gap, y: f.minY + a.along - frame.height / 2)
            case .left:
                let barX = f.minX + CalibrationMath.barEdgeInset + BarView.thickness
                origin = NSPoint(x: barX + gap, y: f.minY + a.along - frame.height / 2)
            case .top:
                let barY = f.maxY - CalibrationMath.barEdgeInset - BarView.thickness
                origin = NSPoint(x: f.minX + a.along - frame.width / 2, y: barY - frame.height - gap)
            case .bottom:
                let barY = f.minY + CalibrationMath.barEdgeInset + BarView.thickness
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
        valueLabel.stringValue = inches > 0 ? String(format: "%.1f″", inches) : Copy.matchReadoutPlaceholder
    }

    @objc private func saveTapped() { onSave?() }
    @objc private func cancelTapped() { onCancel?() }
}

/// A seamstress's measuring tape hugging the seam: a soft cream ribbon ruled in
/// inches along one edge (down to eighths) and centimeters along the other —
/// dual-scale, like every tailor's tape since forever — with a small metal crimp
/// tab at each end. The honest tape is ruled at the reference's true pitch; the
/// liar's at her EDID-claimed pitch, so a physical match reads as two different
/// numbers. Drag either tab to let tape out or take it in; grab the ribbon
/// anywhere to slide the whole thing along the seam; arrow keys nudge the length
/// for the final millimeter. Chalk lines (pink for x tapes, yellow for y) struck perpendicular from both
/// ends let the two tapes be sighted across the gap. The only label is the unit
/// printed over the ribbon — "inches" on the trusted tape, her "inches" on the
/// one being measured. Reports its live length so the controller can infer the
/// target's PPI. Purely an affordance — the readout and Save/Cancel live in the
/// floating panel.
private final class BarView: NSView {
    var onResize: ((CGFloat) -> Void)?
    /// ⏎ pressed while this tape has keys: save the calibration.
    var onCommit: (() -> Void)?
    /// ⎋ pressed while this tape has keys: cancel out.
    var onCancel: (() -> Void)?

    private var length: CGFloat
    private var offset: CGFloat = 0        // slide of the bar's center along the seam
    private let anchor: BarPlacement?
    /// Tick pitch in points: the reference's true points-per-inch on the honest
    /// tape, but the *EDID-claimed* pitch on the liar's — so at a physical match
    /// the two ribbons read different numbers. Her inches, as told by her.
    private let pointsPerInch: CGFloat
    /// Printed over the ribbon's midpoint — "inches" on the trusted tape, her
    /// "inches" on the one still being measured. This is how the tapes are told
    /// apart; there are no other labels.
    private let unitLabel: String
    /// Brand lettering on the ribbon: the trusted tape wears the house brand, the
    /// liar's wears something appropriately off-brand.
    private let brand: String
    private let finePrint: String
    private let palette: Palette

    /// Everything that differs between the honest tape and the vanity knockoff.
    /// Same ribbon, same rules — different boutique.
    struct Palette {
        let ribbon: NSColor      // the ribbon's base color
        let edge: NSColor        // the ribbon's outline
        let ink: NSColor         // inch scale and numbers
        let accent: NSColor      // cm scale and numbers
        let stitch: NSColor      // the dashed stitch lines
        let brandColor: NSColor
        let finePrintColor: NSColor
        let tipLight: NSColor    // crimp-tab metal gradient
        let tipDark: NSColor
        let crest: String        // printed beside the brand

        /// Warm cream vinyl, black-ish ink, red metric, silver tips — a tape that's
        /// lived an honest life in a sewing box.
        static let honest = Palette(
            ribbon: NSColor(calibratedRed: 0.99, green: 0.97, blue: 0.91, alpha: 0.97),
            edge: NSColor(calibratedRed: 0.45, green: 0.4, blue: 0.3, alpha: 0.5),
            ink: NSColor(calibratedRed: 0.15, green: 0.12, blue: 0.1, alpha: 1),
            accent: NSColor(calibratedRed: 0.75, green: 0.15, blue: 0.15, alpha: 1),
            stitch: NSColor(calibratedRed: 0.75, green: 0.65, blue: 0.5, alpha: 0.6),
            brandColor: .systemOrange,
            finePrintColor: NSColor(calibratedRed: 0.35, green: 0.3, blue: 0.25, alpha: 1),
            tipLight: NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1),
            tipDark: NSColor(calibratedRed: 0.6, green: 0.62, blue: 0.66, alpha: 1),
            crest: "👑")

        /// Royal purple satin, everything printed in gold, rose-gold tips,
        /// kiss-mark crest — the tape she bought herself. It flatters. That's
        /// its job.
        static let vanity = Palette(
            ribbon: NSColor(calibratedRed: 0.34, green: 0.12, blue: 0.58, alpha: 0.97),
            edge: NSColor(calibratedRed: 0.17, green: 0.05, blue: 0.32, alpha: 0.6),
            ink: NSColor(calibratedRed: 0.96, green: 0.8, blue: 0.38, alpha: 1),
            accent: NSColor(calibratedRed: 0.85, green: 0.66, blue: 0.28, alpha: 1),
            stitch: NSColor(calibratedRed: 0.9, green: 0.74, blue: 0.4, alpha: 0.7),
            brandColor: NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.45, alpha: 1),
            finePrintColor: NSColor(calibratedRed: 0.88, green: 0.72, blue: 0.42, alpha: 1),
            tipLight: NSColor(calibratedRed: 0.98, green: 0.8, blue: 0.74, alpha: 1),
            tipDark: NSColor(calibratedRed: 0.78, green: 0.5, blue: 0.44, alpha: 1),
            crest: "💋")
    }
    /// Ribbon cross-thickness — a tailor's 5/8" ribbon, scaled up enough to read.
    static let thickness: CGFloat = 26
    /// Shortest the tape folds down to.
    private static let minLength: CGFloat = 60
    /// The metal crimp tab at each end: its reach along the ribbon.
    private static let tipAlong: CGFloat = 13

    init(length: CGFloat, anchor: BarPlacement?, pointsPerInch: CGFloat, unitLabel: String,
         brand: String, finePrint: String, palette: Palette) {
        self.length = length; self.anchor = anchor
        self.pointsPerInch = pointsPerInch; self.unitLabel = unitLabel
        self.brand = brand; self.finePrint = finePrint; self.palette = palette
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    /// True while the floating panel is key and routing its arrow keys to this
    /// tape (the controller keeps it in sync with the panel's key status).
    var externallyActive = false {
        didSet { if externallyActive != oldValue { needsDisplay = true } }
    }

    /// Whether arrow keys would land on this tape right now — either directly
    /// (its window is key and it holds first responder) or via the panel.
    private var keyboardIsLive: Bool {
        externallyActive || (window?.isKeyWindow == true && window?.firstResponder === self)
    }

    // Keep the active-tip glow honest as focus moves between the two tape
    // windows and the panel.
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let w = window else { return }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(redrawKeyState), name: NSWindow.didBecomeKeyNotification, object: w)
        nc.addObserver(self, selector: #selector(redrawKeyState), name: NSWindow.didResignKeyNotification, object: w)
    }
    @objc private func redrawKeyState() { needsDisplay = true }

    private var lengthIsVertical: Bool { anchor?.lengthIsVertical ?? false }

    /// The bar's anchored center along the seam (before `offset`).
    private func anchorAlong() -> CGFloat {
        if let a = anchor { return a.along }
        return lengthIsVertical ? bounds.midY : bounds.midX
    }

    private func rect() -> NSRect {
        CalibrationMath.barRect(length: length, offset: offset, thickness: Self.thickness, anchor: anchor, in: bounds)
    }

    /// Along-axis view coordinate of a point.
    private func along(_ p: CGPoint) -> CGFloat { lengthIsVertical ? p.y : p.x }
    private var maxAlong: CGFloat { lengthIsVertical ? bounds.height : bounds.width }

    /// Grab regions in view coordinates: a metal tab at each end (drag to let tape
    /// out or take it in) and the ribbon between them (slide the whole tape).
    private func grabRects(_ r: NSRect) -> (lowTip: NSRect, highTip: NSRect, ribbon: NSRect) {
        let tipSpan = Self.tipAlong + 28      // the tab plus a forgiving halo
        let tipCross = Self.thickness + 30
        if lengthIsVertical {
            let low = NSRect(x: r.midX - tipCross / 2, y: r.minY - 14, width: tipCross, height: tipSpan)
            let high = NSRect(x: r.midX - tipCross / 2, y: r.maxY - tipSpan + 14, width: tipCross, height: tipSpan)
            let ribbon = NSRect(x: r.minX - 10, y: low.maxY,
                                width: r.width + 20, height: max(high.minY - low.maxY, 0))
            return (low, high, ribbon)
        }
        let low = NSRect(x: r.minX - 14, y: r.midY - tipCross / 2, width: tipSpan, height: tipCross)
        let high = NSRect(x: r.maxX - tipSpan + 14, y: r.midY - tipCross / 2, width: tipSpan, height: tipCross)
        let ribbon = NSRect(x: low.maxX, y: r.minY - 10,
                            width: max(high.minX - low.maxX, 0), height: r.height + 20)
        return (low, high, ribbon)
    }

    // MARK: Mouse — the end tabs let tape out/in; the ribbon slides it

    private enum Grab { case none, lowTip, highTip, slide }
    private var grab: Grab = .none
    private var grabDelta: CGFloat = 0   // where in the grabbed part the drag started

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = rect()
        let (lowR, highR, ribbonR) = grabRects(r)
        let start = lengthIsVertical ? r.minY : r.minX
        if highR.contains(p) {
            grab = .highTip; grabDelta = along(p) - (start + length)
        } else if lowR.contains(p) {
            grab = .lowTip; grabDelta = along(p) - start
        } else if ribbonR.contains(p) {
            grab = .slide; grabDelta = along(p) - (start + length / 2)
        } else {
            grab = .none
        }
        if grab != .none { window?.makeFirstResponder(self); needsDisplay = true }
    }
    override func mouseDragged(with event: NSEvent) {
        guard grab != .none else { return }
        apply(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) { grab = .none; needsDisplay = true }

    /// Two tapes share each screen as full-frame siblings; only claim clicks that
    /// actually land on this tape's grab regions so the rest fall through to the
    /// other tape.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let (lowR, highR, ribbonR) = grabRects(rect())
        return (lowR.contains(p) || highR.contains(p) || ribbonR.contains(p)) ? self : nil
    }


    private func apply(_ p: CGPoint) {
        let a = along(p)
        var start = anchorAlong() + offset - length / 2
        var end = start + length
        switch grab {
        case .lowTip:
            start = min(max(a - grabDelta, 0), end - Self.minLength)
        case .highTip:
            end = max(min(a - grabDelta, maxAlong), start + Self.minLength)
        case .slide:
            let c = min(max(a - grabDelta, length / 2), maxAlong - length / 2)
            start = c - length / 2; end = c + length / 2
        case .none:
            return
        }
        commit(start: start, end: end)
    }

    private func commit(start: CGFloat, end: CGFloat) {
        length = end - start
        offset = (start + end) / 2 - anchorAlong()
        onResize?(length)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: Keyboard — dragging is coarse exactly at the scale that matters

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 124, 126: nudge(step)     // → / ↑
        case 123, 125: nudge(-step)    // ← / ↓
        case 36, 76: onCommit?()       // ⏎ / keypad enter
        case 53: onCancel?()           // ⎋
        default: super.keyDown(with: event)
        }
    }

    /// Let tape out (+) or take it in (−) by `delta` points at the far end. When
    /// that end is already at the screen edge, the near end gives instead.
    func nudge(_ delta: CGFloat) {
        var start = anchorAlong() + offset - length / 2
        var end = start + length
        let grown = end + delta
        if grown > maxAlong {
            end = maxAlong
            start = min(max(start - (grown - maxAlong), 0), end - Self.minLength)
        } else {
            end = max(grown, start + Self.minLength)
        }
        commit(start: start, end: end)
    }

    // MARK: Cursor

    override func resetCursorRects() {
        let resize: NSCursor = lengthIsVertical ? .resizeUpDown : .resizeLeftRight
        let (lowR, highR, ribbonR) = grabRects(rect())
        addCursorRect(ribbonR, cursor: .openHand)
        addCursorRect(lowR, cursor: resize)
        addCursorRect(highR, cursor: resize)
    }

    // MARK: Draw

    override func draw(_ dirtyRect: NSRect) {
        // (The soft scrim lives on the window — two sibling tapes shouldn't each
        // darken the screen again.)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = rect()

        // Draw everything in the ribbon's own space — origin at the zero end of the
        // ribbon's bottom edge, +x running out along the tape — so every graduation
        // and all the lettering stays parallel to the direction of travel. Vertical
        // seams rotate the whole tape 90°, zero at the bottom, like measuring an
        // inseam up from the floor.
        ctx.saveGState()
        ctx.translateBy(x: r.midX, y: r.midY)
        if lengthIsVertical { ctx.rotate(by: .pi / 2) }
        ctx.translateBy(x: -length / 2, y: -Self.thickness / 2)

        drawChalk()
        drawRibbon()
        drawBrand()
        drawRuler()
        drawTips()
        drawUnitLabel()
        ctx.restoreGState()
    }

    /// Which side of the blade faces the screen's center, in local space: +1 means
    /// local +y (above the blade), −1 below. The unit label goes on that side so it
    /// never crowds the screen edge the tape hugs.
    private var centerSide: CGFloat {
        switch anchor?.edge {
        case .bottom, .right, .none: return 1
        case .top, .left: return -1
        }
    }

    /// This tape's chalk: yellow for the y-measuring (vertical) tapes, hot pink
    /// for x — two axes, two sticks of tailor's chalk, no cross-axis confusion.
    private var chalkColor: NSColor {
        lengthIsVertical
            ? NSColor(calibratedRed: 1.0, green: 0.86, blue: 0.25, alpha: 1)
            : NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.66, alpha: 1)
    }

    /// Tailor's chalk lines struck perpendicular from both ends of the ribbon,
    /// all the way across the screen — she marks before she cuts. Does what the
    /// laser level would, but this is an atelier. Layered dashed passes fake the
    /// grain of a struck line; the thin final pass keeps a crisp core to
    /// actually sight against.
    private func drawChalk() {
        let reach = max(bounds.width, bounds.height) * 2
        let chalk = chalkColor
        let passes: [(width: CGFloat, alpha: CGFloat, dash: [CGFloat], phase: CGFloat)] = [
            (9,   0.10, [],     0),   // powder halo
            (3.4, 0.28, [9, 3], 0),   // grain
            (2.2, 0.32, [4, 5], 6),   // more grain, out of phase
            (1.1, 0.85, [],     0),   // the crisp line she actually struck
        ]
        for x in [CGFloat(0), length] {
            for pass in passes {
                let line = NSBezierPath()
                line.move(to: CGPoint(x: x, y: -reach)); line.line(to: CGPoint(x: x, y: reach))
                line.lineWidth = pass.width
                if !pass.dash.isEmpty { line.setLineDash(pass.dash, count: pass.dash.count, phase: pass.phase) }
                chalk.withAlphaComponent(pass.alpha).setStroke()
                line.stroke()
            }
        }
    }

    /// The ribbon: warm cream vinyl, gently shaded at the edges so it reads as a
    /// soft flat tape rather than a steel blade, with a faint stitch line along
    /// each edge because someone in the atelier insisted.
    private func drawRibbon() {
        let base = palette.ribbon
        let ribbon = NSRect(x: 0, y: 0, width: length, height: Self.thickness)
        let path = NSBezierPath(roundedRect: ribbon, xRadius: 3.5, yRadius: 3.5)
        NSGradient(colors: [
            base.blended(withFraction: 0.12, of: .black) ?? base,
            base,
            base,
            base.blended(withFraction: 0.10, of: .black) ?? base,
        ])?.draw(in: path, angle: 90)
        palette.edge.setStroke()
        path.lineWidth = 1; path.stroke()

        // Stitch lines: dashed, just inside each long edge.
        let stitch = NSBezierPath(); stitch.lineWidth = 0.7
        stitch.setLineDash([3, 2.5], count: 2, phase: 0)
        stitch.move(to: CGPoint(x: 3, y: 2.2)); stitch.line(to: CGPoint(x: length - 3, y: 2.2))
        stitch.move(to: CGPoint(x: 3, y: Self.thickness - 2.2))
        stitch.line(to: CGPoint(x: length - 3, y: Self.thickness - 2.2))
        palette.stitch.setStroke()
        stitch.stroke()
    }

    /// The printed rule, dual-scale like every tailor's tape: inches along the top
    /// edge (down to eighths) with an upright number at each one, centimeters along
    /// the bottom with a little red number every five. Nobody asked for the metric
    /// side. She provides regardless.
    private func drawRuler() {
        guard pointsPerInch > 8 else { return }
        let ink = palette.ink
        let red = palette.accent

        // Inch graduations hanging from the top edge; skip eighths if too coarse.
        let eighth = pointsPerInch / 8
        let step = eighth >= 3.5 ? 1 : 2
        let ticks = NSBezierPath(); ticks.lineWidth = 1
        var i = step
        while CGFloat(i) * eighth < length - 1 {
            let x = CGFloat(i) * eighth
            let drop: CGFloat
            if i % 8 == 0      { drop = Self.thickness * 0.46 }   // inch
            else if i % 4 == 0 { drop = Self.thickness * 0.32 }   // half
            else if i % 2 == 0 { drop = Self.thickness * 0.24 }   // quarter
            else               { drop = Self.thickness * 0.15 }   // eighth
            ticks.move(to: CGPoint(x: x, y: Self.thickness - 3))
            ticks.line(to: CGPoint(x: x, y: Self.thickness - 3 - drop))
            i += step
        }
        ink.withAlphaComponent(0.8).setStroke(); ticks.stroke()

        // Inch numbers, tucked under their graduation.
        let wholeInches = Int(length / pointsPerInch)
        if wholeInches >= 1 {
            for n in 1...wholeInches {
                let str = NSAttributedString(string: "\(n)", attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: ink,
                ])
                str.draw(at: CGPoint(x: CGFloat(n) * pointsPerInch + 2.5, y: Self.thickness * 0.28))
            }
        }

        // Centimeter graduations rising from the bottom edge, halves included.
        let cm = pointsPerInch / 2.54
        let cmTicks = NSBezierPath(); cmTicks.lineWidth = 0.8
        var j = 1
        while CGFloat(j) * (cm / 2) < length - 1 {
            let x = CGFloat(j) * (cm / 2)
            let rise = Self.thickness * (j % 2 == 0 ? 0.22 : 0.12)
            cmTicks.move(to: CGPoint(x: x, y: 3))
            cmTicks.line(to: CGPoint(x: x, y: 3 + rise))
            j += 1
        }
        red.withAlphaComponent(0.75).setStroke(); cmTicks.stroke()

        // A tiny red number every 5 cm.
        var k = 5
        while CGFloat(k) * cm < length - 1 {
            NSAttributedString(string: "\(k)", attributes: [
                .font: NSFont.systemFont(ofSize: 5.5, weight: .bold),
                .foregroundColor: red,
            ]).draw(at: CGPoint(x: CGFloat(k) * cm + 1.5, y: 3.5))
            k += 5
        }
    }

    /// Ribbon lettering after the first inch: her crest, the brand, and the
    /// compliance fine print. None of it is necessary. That is the point.
    private func drawBrand() {
        guard length > pointsPerInch * 3.2 else { return }
        let x = pointsPerInch * 1.18
        let crest = NSAttributedString(string: palette.crest, attributes: [.font: NSFont.systemFont(ofSize: 8)])
        crest.draw(at: CGPoint(x: x - 13, y: Self.thickness * 0.34))
        NSAttributedString(string: brand, attributes: [
            .font: NSFont.systemFont(ofSize: 7, weight: .black),
            .foregroundColor: palette.brandColor,
        ]).draw(at: CGPoint(x: x, y: Self.thickness * 0.36))
        NSAttributedString(string: finePrint, attributes: [
            .font: NSFont.systemFont(ofSize: 4.5, weight: .semibold),
            .foregroundColor: palette.finePrintColor,
        ]).draw(at: CGPoint(x: x, y: Self.thickness * 0.36 - 6))
    }

    /// The metal crimp tab at each end of the ribbon — folded metal, two crimp
    /// teeth, and a hang hole at each end for sewing-box nails it will never
    /// see. The tab that would move right now — the one being dragged, or the
    /// far tip while arrow keys are live — wears a glow in the tape's chalk color.
    private func drawTips() {
        let metal = NSGradient(colors: [palette.tipLight, palette.tipDark])
        let metalEdge = palette.tipDark.blended(withFraction: 0.5, of: .black) ?? palette.tipDark

        // Which end to spotlight: whichever tab is mid-drag, else the far tip
        // when arrow keys would land here. nil = no glow.
        let glowZeroEnd: Bool? = switch grab {
        case .lowTip: true
        case .highTip: false
        case .none, .slide: keyboardIsLive ? false : nil
        }

        for (x0, isZeroEnd) in [(-1.5, true), (length - Self.tipAlong + 1.5, false)] {
            // The tab barely overhangs the ribbon's edges — crimped metal sits
            // nearly flush, it doesn't wear shoulder pads.
            let tab = NSRect(x: x0, y: -1, width: Self.tipAlong, height: Self.thickness + 2)
            // Rounded only at the outer end; the tape-facing edge is a square
            // crimp, the way folded metal actually bites a ribbon.
            let path = tipPath(tab, roundedEndIsMax: !isZeroEnd)

            if glowZeroEnd == isZeroEnd {
                // Halo in this tape's chalk color, widening and fading outward.
                let glow = chalkColor
                for (inset, alpha, width): (CGFloat, CGFloat, CGFloat) in [(-2, 0.55, 2), (-5, 0.28, 3), (-8, 0.12, 4)] {
                    let halo = NSBezierPath(roundedRect: tab.insetBy(dx: inset, dy: inset),
                                            xRadius: 2.5 - inset, yRadius: 2.5 - inset)
                    glow.withAlphaComponent(alpha).setStroke(); halo.lineWidth = width; halo.stroke()
                }
            }

            metal?.draw(in: path, angle: 90)
            metalEdge.withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1; path.stroke()

            // The crimp teeth: two lines where the metal folds over the ribbon.
            let crimpX = isZeroEnd ? tab.maxX - 3 : tab.minX + 3
            let crimp = NSBezierPath(); crimp.lineWidth = 0.8
            crimp.move(to: CGPoint(x: crimpX, y: tab.minY + 2)); crimp.line(to: CGPoint(x: crimpX, y: tab.maxY - 2))
            let crimpX2 = isZeroEnd ? tab.maxX - 6 : tab.minX + 6
            crimp.move(to: CGPoint(x: crimpX2, y: tab.minY + 2)); crimp.line(to: CGPoint(x: crimpX2, y: tab.maxY - 2))
            metalEdge.withAlphaComponent(0.7).setStroke(); crimp.stroke()

            // Hang hole near the outer (rounded) end of each tab — one per end,
            // because the sewing box has two nails and she's not choosing.
            let holeX = isZeroEnd ? tab.minX + 3 : tab.maxX - 7
            let hole = NSBezierPath(ovalIn: NSRect(x: holeX, y: tab.midY - 2, width: 4, height: 4))
            NSColor.black.withAlphaComponent(0.45).setFill(); hole.fill()
        }
    }

    /// A crimp-tab outline rounded only at one end along the x axis: the outer
    /// (`roundedEndIsMax` picks which) — the other end stays square where the
    /// metal folds over the ribbon.
    private func tipPath(_ r: NSRect, roundedEndIsMax: Bool) -> NSBezierPath {
        let rad: CGFloat = 2.5
        let p = NSBezierPath()
        if roundedEndIsMax {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.line(to: CGPoint(x: r.maxX - rad, y: r.minY))
            p.appendArc(withCenter: CGPoint(x: r.maxX - rad, y: r.minY + rad),
                        radius: rad, startAngle: -90, endAngle: 0)
            p.line(to: CGPoint(x: r.maxX, y: r.maxY - rad))
            p.appendArc(withCenter: CGPoint(x: r.maxX - rad, y: r.maxY - rad),
                        radius: rad, startAngle: 0, endAngle: 90)
            p.line(to: CGPoint(x: r.minX, y: r.maxY))
        } else {
            p.move(to: CGPoint(x: r.maxX, y: r.maxY))
            p.line(to: CGPoint(x: r.minX + rad, y: r.maxY))
            p.appendArc(withCenter: CGPoint(x: r.minX + rad, y: r.maxY - rad),
                        radius: rad, startAngle: 90, endAngle: 180)
            p.line(to: CGPoint(x: r.minX, y: r.minY + rad))
            p.appendArc(withCenter: CGPoint(x: r.minX + rad, y: r.minY + rad),
                        radius: rad, startAngle: 180, endAngle: 270)
            p.line(to: CGPoint(x: r.maxX, y: r.minY))
        }
        p.close()
        return p
    }

    /// The tape's name — "inches" or her "inches" — in white over the blade's
    /// midpoint, parallel to the blade, on the side facing the screen's center.
    private func drawUnitLabel() {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 4
        let str = NSAttributedString(string: unitLabel, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.white,
            .shadow: shadow,
        ])
        let size = str.size()
        let gap: CGFloat = 14
        let y = centerSide > 0 ? Self.thickness + gap : -gap - size.height
        str.draw(at: CGPoint(x: length / 2 - size.width / 2, y: y))
    }
}
