import AppKit

/// Visual "match the tapes" calibration.
///
/// Each display wears two tapes: one along its edge nearest the other display
/// (spanning the full edge — the seam picks the edge but doesn't cap the tape),
/// and one along a perpendicular edge — the bottom, except a built-in laptop
/// panel uses its top, since the laptop sits on the desk with its screen below
/// the monitor's.
///
/// A screen's two tapes are linked — and both screens link at the SUSPECT's
/// claimed aspect ratio, so the physical ratio between a pair's two tapes is
/// identical on both sides. That's what makes the pairs interchangeable:
/// matching the perpendicular tapes implies exactly the same scale as matching
/// the primary ones, no measurement error from mixing. Each tape is ruled at
/// its own axis's pitch — the trusted screen's true points-per-inch, the
/// target's EDID-claimed pitch. A linked resize never clamps the partner: if
/// it would run off its screen, it goes translucent instead — visibly invalid
/// for measuring. Each tape also echoes its partner's length as dashed lines
/// in the partner's chalk color, centered on the tape's own middle — so a
/// physically rotated screen still shows a matching-colored pair to sight
/// against.
///
/// The seam-facing (primary) pair is the measurement of record (the perp pair
/// implies the same scale by construction). Her EDID shape is trusted; her
/// scale is corrected:
///
///   trueSize = claimedSize × (refInches / herInches)
///
/// ⏎ saves and ⎋ cancels from anywhere — the panel or either tape.
@MainActor
final class CalibrationController {

    private var refWindow: NSWindow?
    private var targetWindow: NSWindow?
    private var panels: [(screen: NSScreen, panel: CalibrationPanel)] = []   // one per screen, same controls
    private var target: DisplaySnapshot?
    private weak var targetTape: Tape?       // for arrow-key nudges routed via the panel
    private weak var targetHost: TapeHost?   // for the panel-key → tip-glow sync
    private var keyObservers: [NSObjectProtocol] = []   // panel key-status → tape glow

    private var refPPT: Double = 0             // trusted reference PPI (fallback pitch)
    // One implicit physical measurement per screen — every tape on a screen shows
    // this same length in its own axis's pitch, so there is never a question of
    // which tape the user meant to commit.
    private var refMeasure: Double = 0         // trusted screen, true inches
    private var targetMeasure: Double = 0      // target screen, her claimed inches
    private var refPitch: (x: Double, y: Double) = (0, 0)
    private var targetPitch: (x: Double, y: Double) = (0, 0)
    private var targetClaimedSize: CGSize = .zero   // her EDID story, in inches

    /// Called after a save or cancel so the owner can refresh.
    var onComplete: (() -> Void)?

    func begin(target: DisplaySnapshot, reference: DisplaySnapshot) {
        guard let refPPT = reference.pointsPerInch, refPPT > 0,
              let refScreen = NSScreen.screen(for: reference.id),
              let targetScreen = NSScreen.screen(for: target.id) else {
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
        let refEdge = seam.map { CalibrationMath.seamEdge($0, selfIsA: refIsA) }
            ?? deskEdge(for: reference)
        let targetEdge = seam.map { CalibrationMath.seamEdge($0, selfIsA: !refIsA) }
            ?? deskEdge(for: target)

        // Two tapes per screen: the seam-facing edge, plus a perpendicular one —
        // the bottom by convention, except a laptop panel uses its top (the laptop
        // is on the desk; its top edge is the one near the monitor's bottom). Each
        // pair is an independent axis measurement.
        let (refPlace, refFull) = fullEdgePlacement(refEdge, on: refScreen)
        let (refPerpPlace, refPerpFull) = fullEdgePlacement(perpendicularEdge(to: refEdge, for: reference), on: refScreen)
        let (targetPlace, targetFull) = fullEdgePlacement(targetEdge, on: targetScreen)
        let (targetPerpPlace, targetPerpFull) = fullEdgePlacement(perpendicularEdge(to: targetEdge, for: target), on: targetScreen)
        // Per-axis pitches: the trusted screen's true points-per-inch, and the
        // pitch the target *claims* over EDID — shape trusted, scale on trial.
        // When she won't even claim a size, assume the trusted pitch.
        refPitch = CalibrationMath.axisPitches(bounds: reference.bounds, sizeMM: reference.physicalSizeMM)
            ?? (x: refPPT, y: refPPT)
        if let claimed = CalibrationMath.axisPitches(bounds: target.bounds, sizeMM: target.edidSizeMM) {
            targetPitch = claimed
            targetClaimedSize = CGSize(width: Double(target.edidSizeMM.width) / 25.4,
                                       height: Double(target.edidSizeMM.height) / 25.4)
        } else {
            targetPitch = (x: refPPT, y: refPPT)
            targetClaimedSize = CGSize(width: Double(target.bounds.width) / refPPT,
                                       height: Double(target.bounds.height) / refPPT)
        }
        let primaryVertical = targetPlace.lengthIsVertical
        func pitch(_ p: (x: Double, y: Double), vertical: Bool) -> Double { vertical ? p.y : p.x }
        let refPrimaryPitch = pitch(refPitch, vertical: primaryVertical)
        let refPerpPitch = pitch(refPitch, vertical: !primaryVertical)
        let targetPrimaryPitch = pitch(targetPitch, vertical: primaryVertical)
        let targetPerpPitch = pitch(targetPitch, vertical: !primaryVertical)

        // Both screens link their pair at the SUSPECT's claimed aspect: the ratio
        // between perpendicular and primary physical lengths is `k` on both
        // sides, so matching either same-axis pair implies the same scale.
        let k = primaryVertical
            ? Double(targetClaimedSize.width) / Double(targetClaimedSize.height)
            : Double(targetClaimedSize.height) / Double(targetClaimedSize.width)

        // The suspect's tapes start at 90% of her own edges (her claimed aspect,
        // out of her corners). The trusted pair starts at 90% too, shrunk if the
        // k-linked perpendicular tape wouldn't fit its own edge.
        let f0 = 0.9
        targetMeasure = f0 * Double(targetFull) / targetPrimaryPitch
        refMeasure = min(f0 * Double(refFull) / refPrimaryPitch,
                         f0 * Double(refPerpFull) / refPerpPitch / k)

        // Both tapes wear the same look; the unit printed on the blade — "inches"
        // vs her "inches" — is what tells them apart. Reference tapes (trusted
        // screen): pure measuring affordances, no controls.
        let refTape = Tape(length: CGFloat(refMeasure * refPrimaryPitch), anchor: refPlace,
                           pointsPerInch: CGFloat(refPrimaryPitch), unitLabel: Copy.matchUnitReference,
                           brand: Copy.matchTapeBrandReference, finePrint: Copy.matchTapeFinePrintReference,
                           palette: .honest)
        let refPerpTape = Tape(length: CGFloat(refMeasure * k * refPerpPitch), anchor: refPerpPlace,
                               pointsPerInch: CGFloat(refPerpPitch), unitLabel: Copy.matchUnitReference,
                               brand: Copy.matchTapeBrandReference, finePrint: Copy.matchTapeFinePrintReference,
                               palette: .honest)
        refTape.onResize = { [weak self, weak refPerpTape] len in
            guard let self else { return }
            self.refMeasure = Double(len) / refPrimaryPitch
            refPerpTape?.setLength(CGFloat(self.refMeasure * k * refPerpPitch))
            self.updateReadout()
        }
        refPerpTape.onResize = { [weak self, weak refTape] len in
            guard let self else { return }
            self.refMeasure = Double(len) / refPerpPitch / k
            refTape?.setLength(CGFloat(self.refMeasure * refPrimaryPitch))
            self.updateReadout()
        }
        refWindow = makeWindow(screen: refScreen,
                               views: [TapeHost(tape: refTape), TapeHost(tape: refPerpTape)])

        // Target tapes (target screen). Their ribbons are ruled at the pitch the
        // display *claims* over EDID — even when a previous calibration knows
        // better — so when the two sides physically match, hers reads a different
        // number than the honest one. The lie, printed on the tape.
        let calTape = Tape(length: CGFloat(f0) * targetFull, anchor: targetPlace,
                           pointsPerInch: CGFloat(targetPrimaryPitch), unitLabel: Copy.matchUnitTarget,
                           brand: Copy.matchTapeBrandTarget, finePrint: Copy.matchTapeFinePrintTarget,
                           palette: .vanity)
        let calPerpTape = Tape(length: CGFloat(f0) * targetPerpFull, anchor: targetPerpPlace,
                               pointsPerInch: CGFloat(targetPerpPitch), unitLabel: Copy.matchUnitTarget,
                               brand: Copy.matchTapeBrandTarget, finePrint: Copy.matchTapeFinePrintTarget,
                               palette: .vanity)
        calTape.onResize = { [weak self, weak calPerpTape] len in
            guard let self else { return }
            self.targetMeasure = Double(len) / targetPrimaryPitch
            calPerpTape?.setLength(len * targetPerpFull / targetFull)
            self.updateReadout()
        }
        calPerpTape.onResize = { [weak self, weak calTape] len in
            guard let self else { return }
            let primaryLen = len * targetFull / targetPerpFull
            self.targetMeasure = Double(primaryLen) / targetPrimaryPitch
            calTape?.setLength(primaryLen)
            self.updateReadout()
        }
        let calHost = TapeHost(tape: calTape)
        targetWindow = makeWindow(screen: targetScreen,
                                  views: [calHost, TapeHost(tape: calPerpTape)])
        targetTape = calTape
        targetHost = calHost

        // Each tape echoes its partner's length in the partner's chalk color —
        // the flip-your-screen affordance (see Tape.drawChalk).
        refTape.partner = refPerpTape; refPerpTape.partner = refTape
        calTape.partner = calPerpTape; calPerpTape.partner = calTape

        // ⏎ / ⎋ work from any tape, not just while the panel is key.
        for tape in [refTape, refPerpTape, calTape, calPerpTape] {
            tape.onCommit = { [weak self] in self?.save() }
            tape.onCancel = { [weak self] in self?.cancel(); self?.onComplete?() }
        }

        // A native floating panel on EACH screen holds the instruction, the live
        // inferred-size readout, and Save/Cancel — wherever the user is looking,
        // Make It Canon is one glance away. The target's panel presents last, so
        // it opens key (its arrows route to the liar's tape).
        panels = [(refScreen, refPlace), (targetScreen, targetPlace)].map { screen, place in
            let panel = CalibrationPanel(displayName: target.name, claimedInches: target.edidDiagonalInches,
                                         lastMeasuredInches: target.physicalSizeIsCalibrated ? target.diagonalInches : 0)
            panel.onSave = { [weak self] in self?.save() }
            panel.onCancel = { [weak self] in self?.cancel(); self?.onComplete?() }
            panel.onNudge = { [weak self] delta in self?.targetTape?.nudge(delta) }
            panel.present(on: screen, near: place)
            return (screen, panel)
        }

        // A panel being key routes its arrows to the liar's tape; keep her
        // active-tip glow in sync as key focus moves among panels and tapes.
        calHost.externallyActive = true
        let nc = NotificationCenter.default
        for (_, panel) in panels {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                keyObservers.append(nc.addObserver(forName: name, object: panel, queue: .main) { [weak self, weak calHost] _ in
                    MainActor.assumeIsolated {
                        calHost?.externallyActive = self?.panels.contains { $0.panel.isKeyWindow } ?? false
                    }
                })
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        updateReadout()
    }

    /// Whether a calibration session is on stage (windows up).
    var isActive: Bool { !panels.isEmpty }

    /// Hand key focus to this screen's calibration panel, if there is one — the
    /// hook for an app-level focus-follows-cursor policy (owned outside this
    /// controller). Deliberately won't steal focus when a window on the same
    /// screen is already key — e.g. a tape the user just grabbed, whose arrow
    /// keys they're using.
    func focusPanel(on screen: NSScreen) {
        guard isActive,
              let panel = panels.first(where: { $0.screen.frame == screen.frame })?.panel,
              !panel.isKeyWindow else { return }
        if let key = NSApp.keyWindow, key.screen?.frame == screen.frame { return }
        panel.makeKeyAndOrderFront(nil)
    }

    func cancel() {
        keyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyObservers.removeAll()
        refWindow?.orderOut(nil); refWindow = nil
        targetWindow?.orderOut(nil); targetWindow = nil
        panels.forEach { $0.panel.orderOut(nil) }; panels = []
        target = nil
    }

    private func inferredSizeInches() -> CGSize? {
        CalibrationMath.inferredSize(claimed: targetClaimedSize,
                                     refMeasure: refMeasure, targetMeasure: targetMeasure)
    }

    private func updateReadout() {
        let diag = inferredSizeInches().map { hypot(Double($0.width), Double($0.height)) } ?? 0
        panels.forEach { $0.panel.setInferredDiagonal(diag) }
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

    private func makeWindow(screen: NSScreen, views: [NSView]) -> NSWindow {
        let window = KeyableBorderlessWindow(contentRect: screen.frame, styleMask: .borderless,
                                             backing: .buffered, defer: false)
        window.isOpaque = false
        // The soft scrim lives on the window so the tapes stacked in it don't
        // each darken the screen again.
        window.backgroundColor = NSColor.black.withAlphaComponent(0.12)
        window.hasShadow = false
        // Above the menu bar so a bar hugging the top edge is still grabbable.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
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

}
