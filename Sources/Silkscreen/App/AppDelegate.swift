import AppKit
import CoreGraphics
import IOKit
import IOKit

/// C callback for display hotplug / reconfiguration. Bounces back to the
/// AppDelegate (carried via the `userInfo` context pointer) on the main queue.
private func displayReconfigCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    // `beginConfiguration` fires once before the batch; ignore it to avoid
    // refreshing against a half-applied state.
    if flags.contains(.beginConfigurationFlag) { return }
    // The callback fires once per display in a batch; coalesce into one refresh so
    // we relayout the arranger a single time (no per-display shuffle).
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { delegate.scheduleRefresh() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let arranger = ArrangementWindows()
    private let calibrationController = CalibrationController()

    private var isLiveDragging = false
    /// Snapshot captured when the arranger was opened, for "Reset".
    private var baselineOrigins: [CGDirectDisplayID: CGPoint] = [:]
    private var baselineModes: [CGDirectDisplayID: CGDisplayMode] = [:]

    private var hotkeyMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        PrefsMigration.migrateIfNeeded()   // carry over profiles/calibration from the old bundle id
        requestAccessibilityIfNeeded()   // needed to see the global ⌘⌥F1 hotkey
        setupMenuBar()
        setupArranger()
        setupHotkey()

        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, context)

        refresh()
        showWindow()
    }

    /// Prompt for Accessibility permission (once), which macOS requires for the global
    /// key monitor to observe the hotkey while other apps are focused.
    private func requestAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    /// ⌘⌥ + Brightness-Down (the F1 key on Mac keyboards) toggles the arranger from
    /// anywhere. That key is a *system-defined* media event, not a plain keyDown. A
    /// local monitor catches it while the arranger is focused, a global one otherwise.
    private func setupHotkey() {
        let handler: (NSEvent) -> Bool = { [weak self] event in
            guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return false }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods == [.command, .option] else { return false }
            // data1: high 16 bits = key code, low bits = state; 0x0A = brightness-down.
            let keyCode = (event.data1 & 0xFFFF0000) >> 16
            let keyDown = (event.data1 & 0xFF00) >> 8 == 0x0A
            guard keyCode == NX_KEYTYPE_BRIGHTNESS_DOWN, keyDown else { return false }
            self?.toggleArranger()
            return true
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined, handler: { _ = handler($0) }) {
            hotkeyMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .systemDefined, handler: { handler($0) ? nil : $0 }) {
            hotkeyMonitors.append(l)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, context)
        hotkeyMonitors.forEach { NSEvent.removeMonitor($0) }
    }

    // MARK: - Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖥"
        // Left-click opens the arranger; right-click shows a menu (just Quit).
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private lazy var statusMenu: NSMenu = {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Arrangement  (⌘⌥F1)", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Debug…", action: #selector(showDebug), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Silkscreen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }()

    private let debugWindow = DebugWindow()
    @objc private func showDebug() { debugWindow.show() }

    @objc private func statusItemClicked() {
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if rightClick {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)   // pop the menu
            statusItem.menu = nil                  // detach so the next left-click hits our action
        } else {
            toggleArranger()
        }
    }

    /// Open the arranger, or close it if it's already open.
    @objc private func toggleArranger() {
        if arranger.isVisible { dismissArranger() } else { showWindow() }
    }

    private func setupArranger() {
        let s = arranger.state
        s.onCommit = { [weak self] origins in self?.commitArrangement(origins) }
        s.onSetMain = { [weak self] id in self?.setMainDisplay(id) }
        s.onSetResolution = { [weak self] id, mode, origins in self?.setResolution(id, mode, origins) }
        s.onSetMirror = { [weak self] slave, master in self?.setMirror(slave: slave, master: master) }
        s.onUnmirror = { [weak self] id in self?.unmirror(id) }
        s.onCalibrate = { [weak self] id in self?.calibrate(id) }
        s.onCalibrateVisual = { [weak self] id in self?.calibrateVisual(id) }
        s.onResetCalibration = { [weak self] id in self?.resetCalibration(id) }
        s.onOpenAirPlaySettings = { [weak self] in self?.openAirPlaySettings() }
        s.onDismiss = { [weak self] in self?.dismissArranger() }
        s.onReset = { [weak self] in self?.resetToBaseline() }
        // A live plane change (drag / nudge / align) marks the session live so the
        // reconfig callback doesn't clobber the working plane.
        let priorChanged = s.changed
        s.changed = { [weak self] in self?.isLiveDragging = true; priorChanged?() }
        calibrationController.onComplete = { [weak self] in self?.refresh() }
    }

    /// Visual match-the-boxes calibration against a trusted reference display.
    private func calibrateVisual(_ id: CGDirectDisplayID) {
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
        // Dismiss the arranger overlay so it doesn't clutter the calibration windows.
        dismissArranger()
        calibrationController.begin(target: target, reference: reference)
    }

    // MARK: - Calibration

    /// Prompt for the display's true diagonal size (EDID can't be trusted) and
    /// store an override keyed to that physical monitor.
    private func calibrate(_ id: CGDirectDisplayID) {
        guard let d = DisplayManager.snapshot().first(where: { $0.id == id }), !d.isBuiltin else { return }

        let alert = NSAlert()
        alert.messageText = "Calibrate \(d.name)"
        alert.informativeText = "Enter the screen's diagonal size in inches (corner to corner of the visible area). EDID currently reports \(String(format: "%.1f", d.diagonalInches))\"."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "e.g. 15.4"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
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
        refresh()
    }

    private func resetCalibration(_ id: CGDirectDisplayID) {
        guard let d = DisplayManager.snapshot().first(where: { $0.id == id }) else { return }
        CalibrationStore.clearOverride(for: d.fingerprint)
        refresh()
    }

    /// Open the Control Center **Screen Mirroring** menu — the honest "manage it" action
    /// for a detected AirPlay session, since public API can't cancel one Silkscreen didn't
    /// start. It has to be the Screen Mirroring menu specifically: Display *Settings*
    /// doesn't know about AirPlay window/app sessions either. There's no public URL for
    /// the Control Center module, so we click its menu-bar item via System Events (needs
    /// Accessibility permission; brittle by nature, hence the best-effort try).
    private func openAirPlaySettings() {
        let script = """
        tell application "System Events" to tell process "ControlCenter" ¬
            to click (first menu bar item of menu bar 1 whose description is "Screen Mirroring")
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }

    /// Apply a reconfiguration and offer a countdown "Revert" at the bottom of every
    /// screen (the arranger is on all of them, so there's no unusable state to trap
    /// the user). `apply` returns false if it couldn't even start.
    private func applyRevertable(apply: () -> Bool, revert: @escaping () -> Void) {
        guard preservingCursor(apply) else { refresh(); return }
        refresh()
        arranger.state.pendingRevert = { [weak self] in
            self?.preservingCursor { revert(); return true }; self?.refresh()
        }
        arranger.state.notify()
    }

    // MARK: - Cursor preservation

    /// Run `body` (a reconfiguration), keeping the cursor at the same fractional spot
    /// within whatever physical display it was on. macOS often teleports the cursor
    /// across a reconfig; this puts it back where the hand expects it.
    @discardableResult
    private func preservingCursor(_ body: () -> Bool) -> Bool {
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

    /// Change a display's resolution, preserving alignment: apply the new mode
    /// *and* re-set the arrangement so the display stays where the plane put it at
    /// the new point size. Reverts both (undoable) if a bad mode blacks a screen.
    private func setResolution(_ id: CGDirectDisplayID, _ mode: CGDisplayMode,
                               _ origins: [CGDirectDisplayID: CGPoint]) {
        isLiveDragging = false
        let snap = DisplayManager.snapshot()
        let previousMode = CGDisplayCopyDisplayMode(id)
        let previousOrigins = originMap(of: snap)
        let mainID = snap.first(where: { $0.isMain })?.id
        applyRevertable(apply: {
            guard DisplayManager.applyMode(mode, to: id) else { return false }
            DisplayManager.applyOrigins(pin(origins, mainID: mainID), permanent: true)
            return true
        }, revert: {
            if let previousMode { DisplayManager.applyMode(previousMode, to: id) }
            DisplayManager.applyOrigins(previousOrigins, permanent: true)
        })
    }

    /// Make `id` the main display. The arrangement geometry is the current plane; we
    /// just shift it so `id` sits at (0,0) (CoreGraphics keys main off the origin), so
    /// the plane — and thus the tiles — don't change.
    private func setMainDisplay(_ id: CGDirectDisplayID) {
        let snapshot = DisplayManager.snapshot()
        guard snapshot.first(where: { $0.id == id })?.isMain == false,
              let origins = arranger.state.originsMakingMain(id) else { return }
        isLiveDragging = false
        let before = originMap(of: snapshot)
        applyRevertable(apply: { DisplayManager.applyOrigins(origins, permanent: true) },
                        revert: { DisplayManager.applyOrigins(before, permanent: true) })
    }

    /// Mirror `slave` onto `master`, then re-snapshot so the slave moves to the mirror
    /// column. Mirroring can blank/relayout screens, so offer the keep/revert.
    private func setMirror(slave: CGDirectDisplayID, master: CGDirectDisplayID) {
        isLiveDragging = false
        applyRevertable(apply: { DisplayManager.setMirror(slave: slave, master: master) },
                        revert: { DisplayManager.unmirror(slave) })
    }

    /// Stop `id` mirroring; it returns to the plane on the next snapshot.
    private func unmirror(_ id: CGDirectDisplayID) {
        let snap = DisplayManager.snapshot()
        guard let master = snap.first(where: { $0.id == id })?.mirrorMaster else { return }
        isLiveDragging = false
        applyRevertable(apply: { DisplayManager.unmirror(id) },
                        revert: { DisplayManager.setMirror(slave: id, master: master) })
    }

    // MARK: - Arrangement commit

    /// Finalize a manipulation (drag or keyboard): apply to the real displays once,
    /// pinning the current main so it never changes. Works for both mouse and keyboard
    /// because neither reconfigures hardware until here, so the live snapshot is still
    /// the "before" state.
    private func commitArrangement(_ origins: [CGDirectDisplayID: CGPoint]) {
        let snap = DisplayManager.snapshot()
        let mainID = snap.first(where: { $0.isMain })?.id
        isLiveDragging = false
        // Rearranging can't strand the user (the arranger is on every screen), so no
        // revert offer — only main/resolution changes arm one.
        let pinned = pin(origins, mainID: mainID)
        preservingCursor { DisplayManager.applyOrigins(pinned, permanent: true) }
        refresh()
    }

    /// Translate an arrangement so `mainID` stays at global (0,0) — CoreGraphics
    /// keys the main display off (0,0), so this guarantees main never changes.
    private func pin(_ origins: [CGDirectDisplayID: CGPoint], mainID: CGDirectDisplayID?) -> [CGDirectDisplayID: CGPoint] {
        guard let mainID, let offset = origins[mainID] else { return origins }
        return origins.mapValues { CGPoint(x: $0.x - offset.x, y: $0.y - offset.y) }
    }

    private func originMap(of snapshot: [DisplaySnapshot]) -> [CGDirectDisplayID: CGPoint] {
        Dictionary(snapshot.map { ($0.id, $0.bounds.origin) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Actions

    @objc func refresh() {
        // Mid-manipulation the shared plane owns the working state; don't clobber it.
        guard !isLiveDragging else { return }
        let displays = DisplayManager.snapshot()
        handleProfiles(displays)
        arranger.refresh(displays: displays)
    }

    private var lastDisplaySet: Set<String> = []
    /// Base v/m/s (ignoring the topology suffix) of the last set, to detect an
    /// identical monitor joining one already present.
    private var lastBaseSet: [String] = []
    /// Session-stable display IDs present last refresh, to find a genuine newcomer.
    private var lastDisplayIDs: Set<CGDirectDisplayID> = []
    /// Each display's global origin at the previous refresh, to re-pin survivors when
    /// one leaves (macOS otherwise moves the remaining monitor).
    private var lastOrigins: [CGDirectDisplayID: CGPoint] = [:]

    /// Auto-save / auto-restore layout profiles. When the connected display *set*
    /// changes (a hotplug), apply the best saved profile for it; otherwise (a settled
    /// state after our own commit) save the current layout as the profile for this set.
    /// If a newly-plugged display isn't covered by any profile, open the arranger and
    /// select it so the user can place it.
    private func handleProfiles(_ displays: [DisplaySnapshot]) {
        let set = Set(displays.map(\.fingerprint))
        let baseSet = displays.map { "\($0.vendor)-\($0.model)-\($0.serial)" }
        let ids = Set(displays.map(\.id))
        let newcomerIDs = ids.subtracting(lastDisplayIDs)
        let removed = lastDisplayIDs.subtracting(ids)
        let priorOrigins = lastOrigins
        defer {
            lastDisplaySet = set; lastBaseSet = baseSet; lastDisplayIDs = ids
            lastOrigins = Dictionary(displays.map { ($0.id, $0.bounds.origin) }, uniquingKeysWith: { a, _ in a })
        }
        guard !set.isEmpty else { return }

        guard set != lastDisplaySet else {
            LayoutStore.store(LayoutStore.profile(from: displays))   // settled → remember this layout
            return
        }

        // A display left: macOS may have moved a survivor to a stale single-monitor
        // layout. Re-pin survivors to their prior positions; if that's impossible
        // (e.g. the middle of three was removed), open the arranger to solve instead.
        if !removed.isEmpty, newcomerIDs.isEmpty {
            repinSurvivors(displays, priorOrigins: priorOrigins)
            return
        }

        // A twin of an already-present monitor just joined: adding it re-suffixes the
        // existing one, but we must NOT reshuffle the existing displays. Leave them put,
        // dock the newcomer flush to the nearest free edge, and arrange it.
        if joinedIdenticalTwin(baseSet) {
            dockNewcomer(newcomerIDs, in: displays)
            selectNewcomer(newcomerIDs, in: displays)
            return
        }

        let profile = LayoutStore.bestMatch(for: Array(set))
        if let profile { applyProfile(profile, to: displays) }

        // Any newly-connected display not covered by the applied profile is
        // "unrecognized" — surface the arranger and select it.
        let recognized = profile.map { Set($0.keys) } ?? []
        let unrecognized = displays.filter { newcomerIDs.contains($0.id) && !recognized.contains($0.fingerprint) }
        selectNewcomer(Set(unrecognized.map(\.id)), in: displays)
    }

    /// Re-apply the survivors' prior origins so the remaining monitor(s) don't get
    /// moved by macOS's stale layout. If those origins no longer form a valid
    /// arrangement (a gap — e.g. the middle of three was removed), open the arranger to
    /// solve to a next-best layout instead.
    private func repinSurvivors(_ displays: [DisplaySnapshot], priorOrigins: [CGDirectDisplayID: CGPoint]) {
        var rects: [CGRect] = []
        var origins: [CGDirectDisplayID: CGPoint] = [:]
        var mainID: CGDirectDisplayID?
        for d in displays {
            guard let o = priorOrigins[d.id] else { showWindow(); return }   // unknown prior → let user solve
            origins[d.id] = o
            rects.append(CGRect(origin: o, size: d.bounds.size))
            if d.isMain { mainID = d.id }
        }
        guard arrangementIsValid(rects) else { showWindow(); return }        // gap/overlap → solve in arranger
        preservingCursor { DisplayManager.applyOrigins(pin(origins, mainID: mainID), permanent: true) }
    }

    /// Whether `rects` form a connected, non-overlapping arrangement (each touches
    /// another edge-to-edge, none overlap).
    private func arrangementIsValid(_ rects: [CGRect]) -> Bool {
        guard rects.count > 1 else { return true }
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count where rects[i].insetBy(dx: 1, dy: 1).intersects(rects[j].insetBy(dx: 1, dy: 1)) {
                return false   // overlap
            }
        }
        // Connectivity: BFS over edge-adjacency must reach every rect.
        var seen = Set([0]); var queue = [0]
        while let k = queue.popLast() {
            for n in 0..<rects.count where !seen.contains(n) && edgeAdjacent(rects[k], rects[n]) {
                seen.insert(n); queue.append(n)
            }
        }
        return seen.count == rects.count
    }

    private func edgeAdjacent(_ a: CGRect, _ b: CGRect) -> Bool {
        let tol: CGFloat = 2
        let xTouch = abs(a.maxX - b.minX) <= tol || abs(b.maxX - a.minX) <= tol
        let yTouch = abs(a.maxY - b.minY) <= tol || abs(b.maxY - a.minY) <= tol
        let yOv = min(a.maxY, b.maxY) - max(a.minY, b.minY) > tol
        let xOv = min(a.maxX, b.maxX) - max(a.minX, b.minX) > tol
        return (xTouch && yOv) || (yTouch && xOv)
    }

    /// Dock a newly-joined display flush to the nearest free edge of the existing
    /// arrangement (macOS may have dropped it overlapping or off in the void).
    private func dockNewcomer(_ newcomerIDs: Set<CGDirectDisplayID>, in displays: [DisplaySnapshot]) {
        guard let newID = newcomerIDs.first,
              let newD = displays.first(where: { $0.id == newID }) else { return }
        let others = displays.filter { $0.id != newID }
        guard !others.isEmpty else { return }
        let newRect = newD.bounds

        // If the OS spot already touches an edge without overlapping, leave it.
        let overlaps = others.contains { $0.bounds.insetBy(dx: 1, dy: 1).intersects(newRect.insetBy(dx: 1, dy: 1)) }
        let touches = others.contains { edgeAdjacent($0.bounds, newRect) }
        if touches && !overlaps { return }

        // Dock flush to the nearest neighbor's edge without overlapping.
        var best = newRect.origin; var bestDist = CGFloat.greatestFiniteMagnitude
        for o in others {
            let r = o.bounds
            for cand in [CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX - newRect.width, y: r.minY),
                         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY - newRect.height)] {
                let placed = CGRect(origin: cand, size: newRect.size).insetBy(dx: 1, dy: 1)
                if others.contains(where: { $0.bounds.intersects(placed) }) { continue }
                let dist = hypot(cand.x - newRect.minX, cand.y - newRect.minY)
                if dist < bestDist { bestDist = dist; best = cand }
            }
        }
        var origins = originMap(of: displays)
        origins[newID] = best
        let mainID = displays.first(where: \.isMain)?.id
        preservingCursor { DisplayManager.applyOrigins(pin(origins, mainID: mainID), permanent: true) }
    }

    /// True when the base v/m/s multiset grew by exactly one that was already present —
    /// i.e. a second identical monitor was plugged in.
    private func joinedIdenticalTwin(_ baseSet: [String]) -> Bool {
        guard baseSet.count == lastBaseSet.count + 1 else { return false }
        let before = Dictionary(lastBaseSet.map { ($0, 1) }, uniquingKeysWith: +)
        let now = Dictionary(baseSet.map { ($0, 1) }, uniquingKeysWith: +)
        // Exactly one base id increased its count, and it was already present before.
        let grown = now.filter { $0.value > (before[$0.key] ?? 0) }
        return grown.count == 1 && (before[grown.keys.first!] ?? 0) >= 1
    }

    /// Open the arranger (if needed) and select the first newly-connected display.
    private func selectNewcomer(_ newcomerIDs: Set<CGDirectDisplayID>, in displays: [DisplaySnapshot]) {
        guard let id = newcomerIDs.first, displays.contains(where: { $0.id == id }) else { return }
        if !arranger.isVisible { showWindow() }
        arranger.state.selectedID = id
        arranger.state.notify()
    }

    /// Apply a saved profile to the matching connected displays: set each present
    /// display's mode, then its origin (pinning main at 0,0).
    private func applyProfile(_ profile: LayoutStore.Profile, to displays: [DisplaySnapshot]) {
        // `uniqueKeysWithValues` would trap on a fingerprint collision; keep-first
        // instead (the topology suffix should prevent collisions, but degrade safely).
        let byFingerprint = Dictionary(displays.map { ($0.fingerprint, $0) }, uniquingKeysWith: { a, _ in a })
        var origins: [CGDirectDisplayID: CGPoint] = [:]
        var mainID: CGDirectDisplayID?
        preservingCursor {
            for (fp, e) in profile {
                guard let d = byFingerprint[fp] else { continue }
                if let mode = ModeCatalog.mode(for: d.id, matching: e) { DisplayManager.applyMode(mode, to: d.id) }
                origins[d.id] = CGPoint(x: e.originX, y: e.originY)
                if e.isMain { mainID = d.id }
            }
            return DisplayManager.applyOrigins(pin(origins, mainID: mainID), permanent: true)
        }
    }

    private var refreshScheduled = false

    /// Coalesce the per-display reconfig callbacks into one refresh at the end of the
    /// run loop turn, so a batch (e.g. a main-display change) relayouts just once.
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    @objc func showWindow() {
        let displays = DisplayManager.snapshot()
        // Capture the current layout + resolutions as the "Reset" baseline.
        baselineOrigins = originMap(of: displays)
        baselineModes = Dictionary(displays.compactMap { d in
            CGDisplayCopyDisplayMode(d.id).map { (d.id, $0) }
        }, uniquingKeysWith: { a, _ in a })
        arranger.show(displays: displays)
    }

    /// Restore positions, resolutions, and main to the baseline captured on open.
    private func resetToBaseline() {
        arranger.state.pendingRevert = nil
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

    private func dismissArranger() {
        arranger.hide()
    }
}
