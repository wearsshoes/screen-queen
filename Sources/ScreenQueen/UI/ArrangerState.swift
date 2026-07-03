import AppKit

/// The editing state shared by every per-screen `Arranger`: the physical plane plus
/// selection/preview state and app callbacks. A mutation on any canvas writes here and
/// calls `changed()` so all canvases redraw from the same source of truth.
@MainActor
final class ArrangerState {

    // App callbacks (wired once by the AppDelegate).
    var onCommit: (([CGDirectDisplayID: CGPoint]) -> Void)?
    /// Resolution-slider drag began/ended — ArrangerWindows drives the ghost aids from a
    /// timer while held (the modal tracking loop starves the mouse monitors).
    var onSliderDragChanged: ((Bool) -> Void)?
    var onSetMain: ((CGDirectDisplayID) -> Void)?
    var onSetResolution: ((CGDirectDisplayID, CGDisplayMode, [CGDirectDisplayID: CGPoint]) -> Void)?
    /// Apply resolution changes to one *or many* displays as a single revertable step.
    var onSetResolutions: (([CGDirectDisplayID: CGDisplayMode], [CGDirectDisplayID: CGPoint]) -> Void)?
    var onSetMirror: ((_ slave: CGDirectDisplayID, _ master: CGDirectDisplayID) -> Void)?
    var onUnmirror: ((CGDirectDisplayID) -> Void)?
    var onCalibrate: ((CGDirectDisplayID) -> Void)?
    var onCalibrateVisual: ((CGDirectDisplayID) -> Void)?
    var onResetCalibration: ((CGDirectDisplayID) -> Void)?
    /// Open system Screen Mirroring settings (we can detect AirPlay but not cancel it).
    var onOpenAirPlaySettings: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// Restore everything to the state captured when the arranger was opened.
    var onReset: (() -> Void)?

    /// Called after any mutation so every canvas redraws.
    var changed: (() -> Void)?

    var displays: [DisplaySnapshot] = []
    var selectedID: CGDirectDisplayID?

    /// Live per-display screen capture (nil when unavailable / not started).
    var capture: ScreenCaptureManager?

    /// Whether the live video feed is on (tiles show live content vs. static wallpaper).
    var feedEnabled = false
    var onToggleFeed: ((Bool) -> Void)?

    /// A live macOS-managed AirPlay visual session (nil when none) — detected via a
    /// power assertion, so it catches even the "Window or App" mode with no display ID.
    var airplaySession: AirPlaySession?

    /// The physical plane (inches) — the source of truth while manipulating.
    var plane: [CGDirectDisplayID: CGRect] = [:]

    /// The display whose tile is being dragged right now (shared so its own screen can
    /// brighten). nil when not dragging.
    var draggingDisplayID: CGDirectDisplayID?

    /// Point origins captured at drag start, holding the *unmoved* displays fixed so a
    /// seam between two stationary displays can't flicker from re-solving the whole
    /// plane each frame. Cleared on drag end.
    var lockedPointOrigins: [CGDirectDisplayID: CGPoint]?

    /// Snapshot the current point solve as the drag lock (on mouse-down, before moving).
    func beginDragLock() {
        lockedPointOrigins = SchematicLayout.toPoints(rects: plane, displays: sizedDisplays())
    }
    func endDragLock() { lockedPointOrigins = nil }

    /// Resolution preview (pending until ⌘ released) — one entry in `.one` scope, many in `.all`.
    var pendingSize: [CGDirectDisplayID: CGSize] = [:]
    var pendingModes: [CGDirectDisplayID: CGDisplayMode] = [:]
    /// Single-display view of `pendingModes` for callers that think in one display.
    var pendingMode: (id: CGDirectDisplayID, mode: CGDisplayMode)? {
        get { pendingModes.first.map { ($0.key, $0.value) } }
        set {
            pendingModes.removeAll()
            if let newValue { pendingModes[newValue.id] = newValue.mode }
        }
    }

    /// The previewed mode for `id`, if any.
    func pendingMode(for id: CGDirectDisplayID) -> CGDisplayMode? { pendingModes[id] }

    /// Whether the resolution slider drives one display or all of them proportionally.
    enum SliderScope { case one, all }
    var sliderScope: SliderScope = .one

    /// Active alignment anchors, for the tile arrow markers.
    var activeV: (selfA: VAnchor, otherA: VAnchor, otherID: CGDirectDisplayID)?
    var activeH: (selfA: HAnchor, otherA: HAnchor, otherID: CGDirectDisplayID)?

    /// "Show the Full Wardrobe": reveal extended/off-native-aspect modes. Persisted.
    static let extendedModesKey = "showFullWardrobe"
    var extendedBuiltinModes = UserDefaults.standard.bool(forKey: ArrangerState.extendedModesKey) {
        didSet { UserDefaults.standard.set(extendedBuiltinModes, forKey: Self.extendedModesKey) }
    }

    /// True while ⌘⇧ is held: every canvas ghosts the possible alignment destinations.
    var showAlignGhosts = false

    /// A pending revert for the last main/resolution change (nil ⇒ none). Applied by
    /// Undo once the plane-edit stack is exhausted; set by the AppDelegate.
    var pendingRevert: (() -> Void)?

    // MARK: - Chrome anchor space (unified across screens)

    /// Unified chrome metrics: the largest Dock / menu-bar claim anywhere and the
    /// smallest screen extents, identical on every canvas so chrome placed within them
    /// is in-bounds everywhere. Recomputed by ArrangerWindows on every rebuild.
    var uniformDockInset: CGFloat = 0
    var uniformMenuBarInset: CGFloat = 0
    var minScreenExtent = CGSize(width: 100_000, height: 100_000)

    /// The granny panel's centre as an offset from the screen centre, in **plane
    /// inches** — its own state (moving a tile never moves it), scaling with the
    /// minimap. A drag on any canvas moves it on all of them.
    var solvePanelCenterOffsetInches = CGPoint(x: -5, y: -4)   // lower-left of centre

    // MARK: - Countdowns (the top-of-screen banner)

    /// The two safety countdowns, independent (both can run at once). `.revertModes`:
    /// a whole-cast resolution change might have blacked out every screen. `.feedGuard`:
    /// going live on a big cast might wedge the machine.
    enum CountdownKind: Hashable, CaseIterable { case revertModes, feedGuard }
    struct Countdown {
        var remaining: Int
        let onExpire: () -> Void
    }

    /// Live countdowns by kind (empty ⇒ no banner).
    private(set) var countdowns: [CountdownKind: Countdown] = [:]
    private var countdownTimer: Timer?
    /// Fires whenever a countdown leaves the table for any reason (keep, act-now, expiry).
    var onCountdownResolved: ((CountdownKind) -> Void)?

    /// Start (or restart) a countdown. `onExpire` runs exactly once.
    func armCountdown(_ kind: CountdownKind, seconds: Int, onExpire: @escaping () -> Void) {
        countdowns[kind] = Countdown(remaining: seconds, onExpire: onExpire)
        if countdownTimer == nil {
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                // Scheduled on the main run loop, so this is main-thread.
                MainActor.assumeIsolated { self?.tickCountdowns() }
            }
        }
        notify()
    }

    /// End a countdown early: `keep` = bless the new state; `!keep` = act now.
    func resolveCountdown(_ kind: CountdownKind, keep: Bool) {
        guard let c = countdowns.removeValue(forKey: kind) else { return }
        stopCountdownTimerIfIdle()
        onCountdownResolved?(kind)
        if !keep { c.onExpire() }
        notify()
    }

    private func tickCountdowns() {
        for (kind, var c) in countdowns {
            c.remaining -= 1
            if c.remaining <= 0 {
                countdowns[kind] = nil
                onCountdownResolved?(kind)
                c.onExpire()
            } else {
                countdowns[kind] = c
            }
        }
        stopCountdownTimerIfIdle()
        notify()
    }

    private func stopCountdownTimerIfIdle() {
        guard countdowns.isEmpty else { return }
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    /// Plane snapshots for undoing drag/snap/nudge/align edits (most recent last).
    private var undoStack: [[CGDirectDisplayID: CGRect]] = []

    func notify() { changed?() }

    /// Snapshot the plane before a manipulation gesture, for Undo.
    func pushUndo() { undoStack.append(plane) }

    /// Discard the undo history (e.g. on Reset).
    func clearUndo() { undoStack.removeAll() }

    /// Whether there's anything to undo — a plane edit or a pending revert.
    var canUndo: Bool { !undoStack.isEmpty || pendingRevert != nil }

    /// Pop the last plane edit if there is one, else run the pending revert.
    func undo() {
        if let previous = undoStack.popLast() {
            plane = previous
            commit()
            notify()
        } else if let revert = pendingRevert {
            pendingRevert = nil
            resolveCountdown(.revertModes, keep: true)   // ⌘Z *is* the revert — no double-fire
            revert()
            notify()
        }
    }

    // MARK: - Interpret / commit

    /// Displays laid out on the physical plane (everything that isn't a mirrored slave).
    var planeDisplays: [DisplaySnapshot] { displays.filter { !$0.isMirrored } }
    /// Mirrored slaves — they leave the plane and live in the mirror column.
    var mirroredDisplays: [DisplaySnapshot] { displays.filter(\.isMirrored) }

    func update(with displays: [DisplaySnapshot], force: Bool = false) {
        self.displays = displays
        self.airplaySession = AirPlayMonitor.currentSession()
        let plane = displays.filter { !$0.isMirrored }
        if force || !planeMatches(plane) { self.plane = SchematicLayout.toPlane(plane) }
        pendingSize.removeAll()
        pendingMode = nil
        if let sel = selectedID, !displays.contains(where: { $0.id == sel }) {
            selectedID = nil; activeV = nil; activeH = nil
        }
        if selectedID == nil {
            selectedID = planeDisplays.first(where: { $0.isMain })?.id ?? planeDisplays.first?.id
        }
    }

    /// Whether the plane already represents `snapshot`: same displays/sizes, converting
    /// back to the same point arrangement *up to a global translation* (a main-only
    /// change just re-anchors the origin and mustn't re-interpret the plane).
    private func planeMatches(_ snapshot: [DisplaySnapshot]) -> Bool {
        guard !plane.isEmpty, Set(snapshot.map(\.id)) == Set(plane.keys) else { return false }
        for d in snapshot {
            let ps = SchematicLayout.physSize(d)
            guard let r = plane[d.id], abs(r.width - ps.width) < 0.05, abs(r.height - ps.height) < 0.05 else { return false }
        }
        let ours = SchematicLayout.toPoints(rects: plane, displays: snapshot)
        guard let ref = snapshot.first(where: { $0.isMain }) ?? snapshot.first,
              let ourRef = ours[ref.id] else { return false }
        let ox = ourRef.x - ref.bounds.minX, oy = ourRef.y - ref.bounds.minY
        for d in snapshot {
            guard let o = ours[d.id],
                  abs((o.x - ox) - d.bounds.minX) < 1.5, abs((o.y - oy) - d.bounds.minY) < 1.5 else { return false }
        }
        return true
    }

    /// Effective point size (live during a zoom preview).
    func pointSize(_ d: DisplaySnapshot) -> CGSize { pendingSize[d.id] ?? d.bounds.size }

    /// Plane displays with the effective point size applied. Mirrored slaves excluded.
    func sizedDisplays() -> [DisplaySnapshot] {
        planeDisplays.map { $0.with(bounds: CGRect(origin: $0.bounds.origin, size: pointSize($0))) }
    }

    /// Point-space origins for the current plane — the locked solve during a drag, else
    /// a normal full solve.
    func pointOrigins() -> [CGDirectDisplayID: CGPoint] {
        let sized = sizedDisplays()
        if let locked = lockedPointOrigins, let dragged = draggingDisplayID {
            return SchematicLayout.lockedSolve(rects: plane, displays: sized, locked: locked, dragged: dragged)
        }
        return SchematicLayout.toPoints(rects: plane, displays: sized)
    }

    func currentBars() -> [SeamBar] {
        SchematicLayout.seamBars(sizedDisplays(), rects: plane, origins: pointOrigins())
    }

    /// The display macOS will put the Dock on for the arrangement currently on the plane.
    func predictedDockDisplay() -> CGDirectDisplayID? {
        // Origins and rects must use the *same* (possibly previewed) sizes, or the Dock
        // is predicted onto the wrong display mid-preview.
        let sized = sizedDisplays()
        let origins = SchematicLayout.toPoints(rects: plane, displays: sized)
        var pointRects: [CGDirectDisplayID: CGRect] = [:]
        for d in sized {
            let o = origins[d.id] ?? d.bounds.origin
            pointRects[d.id] = CGRect(origin: o, size: d.bounds.size)
        }
        let mainID = pendingMainID ?? sized.first { $0.isMain }?.id
        return DockPredictor.dockDisplay(pointRects: pointRects, mainID: mainID, edge: DockPredictor.edge())
    }

    /// The display the Dock is on in the committed OS layout right now.
    func currentDockDisplay() -> CGDirectDisplayID? {
        let mainID = pendingMainID ?? displays.first { $0.isMain }?.id
        var pointRects: [CGDirectDisplayID: CGRect] = [:]
        for d in displays { pointRects[d.id] = d.bounds }
        return DockPredictor.dockDisplay(pointRects: pointRects, mainID: mainID, edge: DockPredictor.edge())
    }

    /// The would-be main implied by an in-progress menu-bar drag (nil when not dragging).
    var pendingMainID: CGDirectDisplayID?

    /// Colors keyed by seam (unordered display pair) — via the shared `SeamColorBook` so
    /// the arranger and the always-on seam lights agree.
    func seamColors(_ bars: [SeamBar]) -> [DisplayGraph.SeamKey: NSColor] {
        SeamColorBook.shared.colors(for: bars.map { ($0.aID, $0.bID) })
    }

    func commit() {
        guard !plane.isEmpty else { return }
        onCommit?(SchematicLayout.toPoints(rects: plane, displays: sizedDisplays()))
    }

    /// The current plane as a point arrangement shifted so `id` sits at the origin —
    /// the arrangement with `id` made main, geometry otherwise unchanged.
    func originsMakingMain(_ id: CGDirectDisplayID) -> [CGDirectDisplayID: CGPoint]? {
        guard !plane.isEmpty else { return nil }
        let origins = SchematicLayout.toPoints(rects: plane, displays: sizedDisplays())
        guard let offset = origins[id] else { return nil }
        return origins.mapValues { CGPoint(x: $0.x - offset.x, y: $0.y - offset.y) }
    }
}
