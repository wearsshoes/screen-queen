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
/// The stagecraft: an `Ensemble` casts the two involved screens — one scrimmed
/// window each, holding that screen's two tapes and a control-panel island.
/// The window routes keys (arrows nudge the liar's tape from either screen,
/// ⏎ saves, ⎋ cancels from anywhere).
@MainActor
final class CalibrationController {

    /// The calibration fleet: one scrimmed window per involved screen, above the
    /// menu bar so a tape hugging the top edge is still grabbable. The soft scrim
    /// lives on the window so the tapes stacked in it don't each darken the screen.
    private let ensemble = Ensemble(
        level: NSWindow.Level(rawValue: Int(CGShieldingWindowLevel())),
        backgroundColor: NSColor.black.withAlphaComponent(0.12),
        collectionBehavior: [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary])

    /// What each involved screen shows, staged in `begin` and consumed by `dress`.
    private struct Scene {
        let screen: NSScreen
        let tapes: [Tape]
        let panelPlacement: BarPlacement
    }
    private var scenes: [CGDirectDisplayID: Scene] = [:]
    private var panelIslands: [CGDirectDisplayID: CalibrationPanelHost] = [:]

    private var target: DisplaySnapshot?
    private weak var targetTape: Tape?       // for arrow-key nudges routed via the scene
    private weak var targetHost: TapeHost?   // for the key → tip-glow sync
    private var keyObservers: [NSObjectProtocol] = []   // key-window moves → tape glow

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

    init() {
        ensemble.dress = { [weak self] id, window in self?.dress(window, screenID: id) }
        ensemble.retire = { [weak self] id in self?.panelIslands[id] = nil }
    }

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
            ?? CalibrationMath.deskEdge(isBuiltin: reference.isBuiltin)
        let targetEdge = seam.map { CalibrationMath.seamEdge($0, selfIsA: !refIsA) }
            ?? CalibrationMath.deskEdge(isBuiltin: target.isBuiltin)

        // Two tapes per screen: the seam-facing edge, plus a perpendicular one —
        // the bottom by convention, except a laptop panel uses its top (the laptop
        // is on the desk; its top edge is the one near the monitor's bottom). Each
        // pair is an independent axis measurement.
        let (refPlace, refFull) = CalibrationMath.fullEdgePlacement(refEdge, screenSize: refScreen.frame.size)
        let (refPerpPlace, refPerpFull) = CalibrationMath.fullEdgePlacement(
            CalibrationMath.perpendicularEdge(to: refEdge, isBuiltin: reference.isBuiltin),
            screenSize: refScreen.frame.size)
        let (targetPlace, targetFull) = CalibrationMath.fullEdgePlacement(targetEdge, screenSize: targetScreen.frame.size)
        let (targetPerpPlace, targetPerpFull) = CalibrationMath.fullEdgePlacement(
            CalibrationMath.perpendicularEdge(to: targetEdge, isBuiltin: target.isBuiltin),
            screenSize: targetScreen.frame.size)
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
        // vs her "inches" — is what tells them apart.
        func tape(length: CGFloat, anchor: BarPlacement, pitch: Double, trusted: Bool) -> Tape {
            Tape(length: length, anchor: anchor, pointsPerInch: CGFloat(pitch),
                 unitLabel: trusted ? Copy.matchUnitReference : Copy.matchUnitTarget,
                 brand: trusted ? Copy.matchTapeBrandReference : Copy.matchTapeBrandTarget,
                 finePrint: trusted ? Copy.matchTapeFinePrintReference : Copy.matchTapeFinePrintTarget,
                 palette: trusted ? .honest : .vanity)
        }

        // Reference tapes (trusted screen): pure measuring affordances, no controls.
        let refTape = tape(length: CGFloat(refMeasure * refPrimaryPitch), anchor: refPlace,
                           pitch: refPrimaryPitch, trusted: true)
        let refPerpTape = tape(length: CGFloat(refMeasure * k * refPerpPitch), anchor: refPerpPlace,
                               pitch: refPerpPitch, trusted: true)
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

        // Target tapes (target screen). Their ribbons are ruled at the pitch the
        // display *claims* over EDID — even when a previous calibration knows
        // better — so when the two sides physically match, hers reads a different
        // number than the honest one. The lie, printed on the tape.
        let calTape = tape(length: CGFloat(f0) * targetFull, anchor: targetPlace,
                           pitch: targetPrimaryPitch, trusted: false)
        let calPerpTape = tape(length: CGFloat(f0) * targetPerpFull, anchor: targetPerpPlace,
                               pitch: targetPerpPitch, trusted: false)
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
        targetTape = calTape

        // Each tape echoes its partner's length in the partner's chalk color —
        // the flip-your-screen affordance (see Tape.drawChalk).
        refTape.partner = refPerpTape; refPerpTape.partner = refTape
        calTape.partner = calPerpTape; calPerpTape.partner = calTape

        // ⏎ / ⎋ work from any tape, not just via the scene's key routing.
        for tape in [refTape, refPerpTape, calTape, calPerpTape] {
            tape.onCommit = { [weak self] in self?.save() }
            tape.onCancel = { [weak self] in self?.finish() }
        }

        // Cast the two involved screens; each member's scene holds its tapes and
        // a control-panel island (wherever the user is looking, Make It Canon is
        // one glance away).
        scenes = [
            reference.id: Scene(screen: refScreen, tapes: [refTape, refPerpTape],
                                panelPlacement: refPlace),
            target.id: Scene(screen: targetScreen, tapes: [calTape, calPerpTape],
                             panelPlacement: targetPlace),
        ]
        ensemble.includes = { [ids = Set(scenes.keys)] id in ids.contains(id) }
        ensemble.rebuild()

        // Arrows land on the liar's tape whenever a calibration window is key and
        // no tape host holds them directly; keep her far-tip glow in sync as key
        // focus moves.
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncTargetGlow() }
            })
        }

        NSApp.activate(ignoringOtherApps: true)
        // The target's window opens key — its arrows route to the liar's tape.
        ensemble.windows[target.id]?.makeKeyAndOrderFront(nil)
        syncTargetGlow()
        updateReadout()
    }

    /// Dress one ensemble window: that screen's tapes plus the panel island, under
    /// a scene view that routes window-level keys.
    private func dress(_ window: NSWindow, screenID id: CGDirectDisplayID) {
        guard let scene = scenes[id] else { return }
        let sceneView = CalibrationSceneView(frame: CGRect(origin: .zero, size: window.frame.size))
        sceneView.onNudge = { [weak self] delta in self?.targetTape?.nudge(delta) }
        sceneView.onCommit = { [weak self] in self?.save() }
        sceneView.onCancel = { [weak self] in self?.finish() }
        for tape in scene.tapes {
            let host = TapeHost(tape: tape)
            host.frame = sceneView.bounds
            host.autoresizingMask = [.width, .height]
            sceneView.addSubview(host)
            if tape === targetTape { targetHost = host }
        }
        let island = CalibrationPanelHost(rootView: panelView())
        let size = island.fittingSize
        island.frame = NSRect(origin: CalibrationPanelHost.origin(near: scene.panelPlacement,
                                                                  screen: scene.screen, panelSize: size),
                              size: size)
        sceneView.addSubview(island)
        panelIslands[id] = island
        window.contentView = sceneView
        window.makeFirstResponder(sceneView)
    }

    /// Whether a calibration session is on stage (windows up).
    var isActive: Bool { ensemble.isVisible }

    /// Hand key focus to this screen's calibration window, if it's in the cast —
    /// the hook for the app-level focus-follows-cursor policy. Don't-steal
    /// semantics live in the ensemble.
    func focusPanel(on screen: NSScreen) {
        ensemble.focusWindow(on: screen)
    }

    /// The liar's far-tip glow: lit whenever a calibration window is key and a
    /// tape host isn't itself holding the keys (the scene routes arrows to her).
    private func syncTargetGlow() {
        guard let key = NSApp.keyWindow, ensemble.windows.values.contains(key) else {
            targetHost?.externallyActive = false
            return
        }
        targetHost?.externallyActive = !(key.firstResponder is TapeHost)
    }

    /// Strike the set and tell the owner — the one exit for cancel paths and `save`.
    private func finish() {
        cancel()
        onComplete?()
    }

    func cancel() {
        keyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyObservers.removeAll()
        ensemble.dismiss()
        scenes.removeAll()
        panelIslands.removeAll()
        target = nil
    }

    private func inferredSizeInches() -> CGSize? {
        CalibrationMath.inferredSize(claimed: targetClaimedSize,
                                     refMeasure: refMeasure, targetMeasure: targetMeasure)
    }

    private func panelView() -> CalibrationPanelView {
        let diag = inferredSizeInches().map { hypot(Double($0.width), Double($0.height)) } ?? 0
        return CalibrationPanelView(
            displayName: target?.name ?? "",
            claimedInches: target?.edidDiagonalInches ?? 0,
            lastMeasuredInches: (target?.physicalSizeIsCalibrated ?? false) ? (target?.diagonalInches ?? 0) : 0,
            inferredInches: diag,
            save: { [weak self] in self?.save() },
            cancel: { [weak self] in self?.finish() })
    }

    private func updateReadout() {
        let view = panelView()
        panelIslands.values.forEach { $0.rootView = view }
    }

    private func save() {
        if let target, let size = inferredSizeInches() {
            CalibrationStore.setOverride(CGSize(width: size.width * 25.4, height: size.height * 25.4),
                                         for: target.fingerprint)
        }
        finish()
    }
}

/// The calibration window's content view: hosts the tapes and the panel island,
/// and routes window-level keys (see `TapeKey`) — arrows nudge the liar's tape
/// from either screen, ⏎ saves, ⎋ cancels.
private final class CalibrationSceneView: NSView {
    var onNudge: ((CGFloat) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch TapeKey.decode(code: event.keyCode, shift: event.modifierFlags.contains(.shift)) {
        case .nudge(let delta): onNudge?(delta)
        case .commit: onCommit?()
        case .cancel: onCancel?()
        case nil: super.keyDown(with: event)
        }
    }
}
