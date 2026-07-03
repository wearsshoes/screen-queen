import AppKit

/// When does a resolution change deserve the auto-revert countdown? Only when it
/// touched *every* connected display at once — then there may be no live screen
/// left to fix things from, and the change must be able to un-do itself. (Any
/// partial change leaves a working arranger somewhere; Undo covers those.)
enum RevertPolicy {
    /// True when `changed` covers all of `all` (and there was anything to cover).
    /// A single-display setup qualifies by construction: its one display is `all`.
    static func coversEveryDisplay(changed: Set<CGDirectDisplayID>,
                                   all: Set<CGDirectDisplayID>) -> Bool {
        !all.isEmpty && all.subtracting(changed).isEmpty
    }
}

/// Every display command the arranger can issue, executed at app level. One reference
/// (`ArrangerState.commander`) replaces the old per-command closure wiring; a SwiftUI
/// model can hold the same reference.
@MainActor
protocol DisplayCommanding: AnyObject {
    func commitArrangement(_ origins: [CGDirectDisplayID: CGPoint])
    func setMainDisplay(_ id: CGDirectDisplayID)
    func setResolution(_ id: CGDirectDisplayID, _ mode: CGDisplayMode, _ origins: [CGDirectDisplayID: CGPoint])
    func setResolutions(_ modes: [CGDirectDisplayID: CGDisplayMode], _ origins: [CGDirectDisplayID: CGPoint])
    func setMirror(slave: CGDirectDisplayID, master: CGDirectDisplayID)
    func unmirror(_ id: CGDirectDisplayID)
    func calibrate(_ id: CGDirectDisplayID)
    func calibrateVisual(_ id: CGDirectDisplayID)
    func resetCalibration(_ id: CGDirectDisplayID)
    func openAirPlaySettings()
    func dismissArranger()
    func resetToBaseline()
    // The house menu (in the arranger's bar since the status item became a plain toggle).
    func showSetup()
    func showDebug()
    func toggleSeamLights()
    var seamLightsOn: Bool { get }
}

/// The executor: applies reconfigurations to the real displays (via `DisplayManager`),
/// wraps risky ones in a revert (silent behind Undo; a countdown banner when a change
/// touches *every* display), and keeps the cursor where the hand expects it.
extension AppDelegate: DisplayCommanding {

    // MARK: - Arrangement commit

    /// Finalize a manipulation (drag or keyboard): apply to the real displays once,
    /// pinning the current main so it never changes. Works for both mouse and keyboard
    /// because neither reconfigures hardware until here, so the live snapshot is still
    /// the "before" state.
    func commitArrangement(_ origins: [CGDirectDisplayID: CGPoint]) {
        let snap = DisplayManager.snapshot()
        let mainID = snap.first(where: { $0.isMain })?.id
        isLiveDragging = false
        // Rearranging can't strand the user (the arranger is on every screen), so no
        // revert offer — only main/resolution changes arm one.
        let pinned = pin(origins, mainID: mainID)
        preservingCursor { DisplayManager.applyOrigins(pinned, permanent: true) }
        refresh()
    }

    /// Make `id` the main display. The arrangement geometry is the current plane; we
    /// just shift it so `id` sits at (0,0) (CoreGraphics keys main off the origin), so
    /// the plane — and thus the tiles — don't change.
    func setMainDisplay(_ id: CGDirectDisplayID) {
        let snapshot = DisplayManager.snapshot()
        guard snapshot.first(where: { $0.id == id })?.isMain == false,
              let origins = arranger.state.originsMakingMain(id) else { return }
        isLiveDragging = false
        let before = originMap(of: snapshot)
        applyRevertable(apply: { DisplayManager.applyOrigins(origins, permanent: true) },
                        revert: { DisplayManager.applyOrigins(before, permanent: true) })
    }

    /// Change one display's resolution — a batch of one.
    func setResolution(_ id: CGDirectDisplayID, _ mode: CGDisplayMode,
                       _ origins: [CGDirectDisplayID: CGPoint]) {
        setResolutions([id: mode], origins)
    }

    /// Apply a resolution change to one or more displays (the ⌘± keys, the tile menu,
    /// either slider scope) as a single revertable step, preserving alignment: the
    /// modes apply *and* the arrangement is re-set so every display stays where the
    /// plane put it at the new point sizes. Strict: if any mode fails to take, the
    /// whole batch rolls back — no half-changed cast.
    func setResolutions(_ modes: [CGDirectDisplayID: CGDisplayMode],
                        _ origins: [CGDirectDisplayID: CGPoint]) {
        guard !modes.isEmpty else { return }
        isLiveDragging = false
        let snap = DisplayManager.snapshot()
        let previousModes = Dictionary(uniqueKeysWithValues:
            modes.keys.compactMap { id in CGDisplayCopyDisplayMode(id).map { (id, $0) } })
        let previousOrigins = originMap(of: snap)
        let mainID = snap.first(where: { $0.isMain })?.id
        let restore = {
            for (id, mode) in previousModes { DisplayManager.applyMode(mode, to: id) }
            DisplayManager.applyOrigins(previousOrigins, permanent: true)
        }
        let applied = applyRevertable(apply: {
            var ok = true
            for (id, mode) in modes { ok = DisplayManager.applyMode(mode, to: id) && ok }
            guard ok else { restore(); return false }   // strict: no half-changed cast
            DisplayManager.applyOrigins(pin(origins, mainID: mainID), permanent: true)
            return true
        }, revert: restore)
        // The whole cast changed looks at once → every screen might be dark → the
        // change must be able to snatch itself back. (One display *is* the whole
        // cast on a single-screen setup.)
        if applied, affectsEveryDisplay(Set(modes.keys)) { armRevertCountdown() }
    }

    /// Mirror `slave` onto `master`, then re-snapshot so the slave moves to the mirror
    /// column. Mirroring can blank/relayout screens, so offer the keep/revert.
    func setMirror(slave: CGDirectDisplayID, master: CGDirectDisplayID) {
        isLiveDragging = false
        applyRevertable(apply: { DisplayManager.setMirror(slave: slave, master: master) },
                        revert: { DisplayManager.unmirror(slave) })
    }

    /// Stop `id` mirroring; it returns to the plane on the next snapshot.
    func unmirror(_ id: CGDirectDisplayID) {
        let snap = DisplayManager.snapshot()
        guard let master = snap.first(where: { $0.id == id })?.mirrorMaster else { return }
        isLiveDragging = false
        applyRevertable(apply: { DisplayManager.unmirror(id) },
                        revert: { DisplayManager.setMirror(slave: id, master: master) })
    }

    // MARK: - Calibration

    /// Prompt for the display's true diagonal size (EDID can't be trusted) and
    /// store an override keyed to that physical monitor.
    func calibrate(_ id: CGDirectDisplayID) {
        guard let d = DisplayManager.snapshot().first(where: { $0.id == id }), !d.isBuiltin else { return }

        let alert = NSAlert()
        alert.messageText = Copy.calibrateTitle(d.name)
        // Quote what she *claims* over EDID (the body says "she claims", so it must
        // be her story) — plus our own last measurement when one is on file.
        alert.informativeText = Copy.calibrateBody(
            edidInches: String(format: "%.1f", d.edidDiagonalInches),
            priorInches: d.physicalSizeIsCalibrated ? String(format: "%.1f", d.diagonalInches) : nil)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "e.g. 15.4"
        alert.accessoryView = field
        alert.addButton(withTitle: Copy.save)
        alert.addButton(withTitle: Copy.cancel)
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        // `runModal()` orders the alert front at its own level, which the arranger
        // overlay can still cover. Bump it above the shielding level once the modal
        // loop has presented the window (next runloop tick).
        DispatchQueue.main.async {
            alert.window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            alert.window.orderFrontRegardless()
        }
        guard alert.runModal() == .alertFirstButtonReturn,
              let inches = Double(field.stringValue), inches > 1 else { return }

        let mm = CalibrationStore.sizeMM(diagonalInches: inches,
                                         pixelWidth: Int(d.pixelSize.width),
                                         pixelHeight: Int(d.pixelSize.height))
        CalibrationStore.setOverride(mm, for: d.fingerprint)
        refreshAfterCalibration()
    }

    /// Visual match-the-boxes calibration against a trusted reference display.
    func calibrateVisual(_ id: CGDirectDisplayID) {
        let displays = DisplayManager.snapshot()
        guard let target = displays.first(where: { $0.id == id }), !target.isBuiltin else { return }
        let candidates = displays.filter { $0.id != id && $0.pointsPerInch != nil }
        let reference = candidates.first(where: { $0.isBuiltin })
            ?? candidates.first(where: { $0.physicalSizeIsCalibrated })
            ?? candidates.first
        guard let reference else {
            calibrate(id) // no trusted reference available — fall back to manual entry
            return
        }
        // The arranger stays up underneath: the calibration is an overlay on the
        // trusted and measured screens, and the seam glow below keeps showing the
        // user how to get their cursor from one to the other.
        calibrationController.begin(target: target, reference: reference)
        events.beginFocusFollowing()   // arrow keys nudge the tape on whichever screen you mouse to
    }

    func resetCalibration(_ id: CGDirectDisplayID) {
        guard let d = DisplayManager.snapshot().first(where: { $0.id == id }) else { return }
        CalibrationStore.clearOverride(for: d.fingerprint)
        refreshAfterCalibration()
    }

    // MARK: - Misc commands

    /// Open the Control Center **Screen Mirroring** menu — the honest "manage it" action
    /// for a detected AirPlay session, since public API can't cancel one Screen Queen didn't
    /// start. It has to be the Screen Mirroring menu specifically: Display *Settings*
    /// doesn't know about AirPlay window/app sessions either. There's no public URL for
    /// the Control Center module, so we click its menu-bar item via System Events (needs
    /// Accessibility permission; brittle by nature, hence the best-effort try).
    func openAirPlaySettings() {
        let script = """
        tell application "System Events" to tell process "ControlCenter" ¬
            to click (first menu bar item of menu bar 1 whose description is "Screen Mirroring")
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }

    func dismissArranger() {
        // Dismissing is an intentional act — someone who can find Done/Esc can see
        // their screens, so any live countdown resolves as "keep".
        arranger.state.resolveCountdown(.revertModes, keep: true)
        arranger.state.resolveCountdown(.feedGuard, keep: true)
        arranger.hide()
    }

    /// Restore positions, resolutions, and main to the baseline captured on open.
    func resetToBaseline() {
        arranger.state.pendingRevert = nil
        arranger.state.resolveCountdown(.revertModes, keep: true)   // Reset outranks it
        arranger.state.clearUndo()
        preservingCursor {
            for (id, mode) in baselineModes { DisplayManager.applyMode(mode, to: id) }
            return DisplayManager.applyOrigins(baselineOrigins, permanent: true)
        }
        // Force a re-interpret so the plane returns to the (possibly edited-equivalent)
        // baseline layout, and repaint.
        let displays = DisplayManager.snapshot()
        arranger.refresh(displays: displays, force: true)
    }

    // MARK: - Revert plumbing

    /// Apply a reconfiguration and arm a silent Revert behind Undo (the arranger is
    /// on every screen, so a partial change can't trap the user). Returns whether
    /// `apply` took; a whole-cast resolution change should follow up with
    /// `armRevertCountdown()` — see `affectsEveryDisplay`.
    @discardableResult
    private func applyRevertable(apply: () -> Bool, revert: @escaping () -> Void) -> Bool {
        // A new change retires any counting-down predecessor as kept: `pendingRevert`
        // is about to point at *this* change, and an old countdown firing it would
        // revert the wrong thing.
        arranger.state.resolveCountdown(.revertModes, keep: true)
        guard preservingCursor(apply) else { refresh(); return false }
        refresh()
        arranger.state.pendingRevert = { [weak self] in
            self?.preservingCursor { revert(); return true }; self?.refresh()
        }
        arranger.state.notify()
        return true
    }

    /// Whether a change to `changed` touched *every* connected display — the one case
    /// with no safe screen left to fix things from (a single-display setup counts by
    /// construction). Mirrored slaves ride their master's mode, so they don't count.
    private func affectsEveryDisplay(_ changed: Set<CGDirectDisplayID>) -> Bool {
        RevertPolicy.coversEveryDisplay(
            changed: changed,
            all: Set(DisplayManager.snapshot().filter { !$0.isMirrored }.map(\.id)))
    }

    /// Arm the auto-revert countdown (the banner at the top of every screen): unless
    /// the user says keep, the pending revert fires itself. 12 seconds, like the old
    /// modal `confirmKeep` this replaces — but nothing blocks and nothing steals focus.
    private func armRevertCountdown(seconds: Int = 12) {
        arranger.state.armCountdown(.revertModes, seconds: seconds) { [weak self] in
            guard let self else { return }
            // The notify() fan-out marks the session live, which gates `refresh()`;
            // this *is* the session's safety net, so let the refresh through.
            self.isLiveDragging = false
            guard let revert = self.arranger.state.pendingRevert else { return }
            self.arranger.state.pendingRevert = nil
            revert()
        }
    }

    // MARK: - Cursor preservation

    /// Run `body` (a reconfiguration), keeping the cursor at the same fractional spot
    /// within whatever physical display it was on. macOS often teleports the cursor
    /// across a reconfig; this puts it back where the hand expects it.
    @discardableResult
    func preservingCursor(_ body: () -> Bool) -> Bool {
        // Cursor in global CG coords (top-left origin), and its display + fraction.
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let beforeID = displayContaining(cursor)
        let beforeFraction = beforeID.flatMap { id -> CGPoint? in
            let b = CGDisplayBounds(id)
            guard b.width > 0, b.height > 0 else { return nil }
            return CGPoint(x: (cursor.x - b.minX) / b.width, y: (cursor.y - b.minY) / b.height)
        }

        let ok = body()

        // Warp back to the same fraction of that display's (possibly moved/resized) bounds.
        if let id = beforeID, let f = beforeFraction {
            let b = CGDisplayBounds(id)
            let target = CGPoint(x: b.minX + f.x * b.width, y: b.minY + f.y * b.height)
            CGWarpMouseCursorPosition(target)
            CGAssociateMouseAndMouseCursorPosition(1)   // resync after the warp
        }
        return ok
    }

    private func displayContaining(_ p: CGPoint) -> CGDirectDisplayID? {
        DisplayManager.snapshot().first { CGDisplayBounds($0.id).contains(p) }?.id
    }

    /// Translate an arrangement so `mainID` stays at global (0,0) — CoreGraphics
    /// keys the main display off (0,0), so this guarantees main never changes.
    func pin(_ origins: [CGDirectDisplayID: CGPoint], mainID: CGDirectDisplayID?) -> [CGDirectDisplayID: CGPoint] {
        guard let mainID, let offset = origins[mainID] else { return origins }
        return origins.mapValues { CGPoint(x: $0.x - offset.x, y: $0.y - offset.y) }
    }

    func originMap(of snapshot: [DisplaySnapshot]) -> [CGDirectDisplayID: CGPoint] {
        Dictionary(snapshot.map { ($0.id, $0.bounds.origin) }, uniquingKeysWith: { a, _ in a })
    }
}
