import AppKit

/// The editing state shared by every per-screen `Arranger`: one physical
/// plane and the surrounding selection/preview state, plus the app callbacks. A
/// mutation on any canvas writes here and calls `changed()` so all canvases redraw
/// from the same source of truth.
@MainActor
final class ArrangerState {

    // App callbacks (wired once by the AppDelegate).
    var onCommit: (([CGDirectDisplayID: CGPoint]) -> Void)?
    /// Set the main display (dragging the menu-bar strip onto another tile).
    var onSetMain: ((CGDirectDisplayID) -> Void)?
    var onSetResolution: ((CGDirectDisplayID, CGDisplayMode, [CGDirectDisplayID: CGPoint]) -> Void)?
    /// Apply a resolution change to one *or many* displays as a single revertable step
    /// (the `.all`-scope slider zooms every display at once → one undo).
    var onSetResolutions: (([CGDirectDisplayID: CGDisplayMode], [CGDirectDisplayID: CGPoint]) -> Void)?
    /// Mirror `slave` onto `master` (Option-drag one tile onto another).
    var onSetMirror: ((_ slave: CGDirectDisplayID, _ master: CGDirectDisplayID) -> Void)?
    /// Stop `id` mirroring (the column's un-mirror button).
    var onUnmirror: ((CGDirectDisplayID) -> Void)?
    var onCalibrate: ((CGDirectDisplayID) -> Void)?
    var onCalibrateVisual: ((CGDirectDisplayID) -> Void)?
    var onResetCalibration: ((CGDirectDisplayID) -> Void)?
    /// Open the system Screen Mirroring settings — the honest "manage it" action for a
    /// macOS-managed AirPlay session (which we can detect but not cancel via public API).
    var onOpenAirPlaySettings: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// Restore everything to the state captured when the arranger was opened.
    var onReset: (() -> Void)?

    /// Called after any mutation so every canvas redraws.
    var changed: (() -> Void)?

    var displays: [DisplaySnapshot] = []
    var selectedID: CGDirectDisplayID?

    /// Live per-display screen-content capture (nil when unavailable / not started).
    /// Tiles draw the latest frame for their display, excluding Screen Queen's own overlay.
    var capture: ScreenCaptureManager?

    /// Whether the live video feed is currently on (drives the leftmost toggle button and
    /// whether tiles show live content vs. static wallpaper).
    var feedEnabled = false
    /// Toggle the live feed on/off (wired by ArrangerWindows to start/stop capture).
    var onToggleFeed: ((Bool) -> Void)?

    /// A live macOS-managed AirPlay visual session (nil when none). Detected via a
    /// power assertion, so it catches even the "Window or App" mode that has no
    /// `CGDirectDisplayID` — see `AirPlayMonitor`. Shown as a read-only card in the
    /// right column; we can surface it but not cancel it.
    var airplaySession: AirPlaySession?

    /// The physical plane (inches) — the source of truth while manipulating.
    var plane: [CGDirectDisplayID: CGRect] = [:]

    /// The display whose tile is being dragged right now (shared across canvases so the
    /// dragged display's own screen can brighten its backdrop). nil when not dragging.
    var draggingDisplayID: CGDirectDisplayID?

    /// Point origins captured at drag start, holding the *unmoved* displays fixed for the
    /// drag's duration: only the dragged display is re-solved each frame (docked to whatever it
    /// now abuts), so a seam between two displays that didn't move can't flicker as an artifact
    /// of re-interpreting the whole plane. Cleared on drag end. See `lockedSolve`.
    var lockedPointOrigins: [CGDirectDisplayID: CGPoint]?

    /// Snapshot the current point solve as the drag lock (call on mouse-down, before moving).
    func beginDragLock() {
        lockedPointOrigins = SchematicLayout.toPoints(rects: plane, displays: sizedDisplays())
    }
    func endDragLock() { lockedPointOrigins = nil }

    /// Resolution preview (pending until ⌘ released). `pendingModes` holds the previewed
    /// CGDisplayMode per display — one entry in `.one` scope, many in `.all` scope.
    var pendingSize: [CGDirectDisplayID: CGSize] = [:]
    var pendingModes: [CGDirectDisplayID: CGDisplayMode] = [:]
    /// Back-compat single-display view of `pendingModes` for the callers/drawing that
    /// still think in one display (e.g. the keyboard ⌘± path and boxing preview).
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

    var extendedBuiltinModes = false

    /// True while ⌘⇧ is held: every canvas ghosts the possible alignment destinations.
    var showAlignGhosts = false

    /// A pending revert for the last main/resolution change (nil ⇒ none). Applied by
    /// Undo once the plane-edit stack is exhausted; set by the AppDelegate.
    var pendingRevert: (() -> Void)?

    // MARK: - Chrome anchor space (unified across screens)

    /// Chrome is laid out in a *shared anchor space* — the bar bottom-center, the
    /// banner top-center, the solve panel bottom-left — with the SAME offsets on
    /// every canvas, so "the cursor is on Done" is a positional fact that holds on
    /// every screen (the ghost story rides on this). These are the unified metrics:
    /// the largest Dock / menu-bar claim anywhere, and the smallest screen extents
    /// (chrome placed within them is in-bounds everywhere, however extreme the
    /// aspect ratios). Recomputed by ArrangerWindows on every rebuild.
    var uniformDockInset: CGFloat = 0
    var uniformMenuBarInset: CGFloat = 0
    var minScreenExtent = CGSize(width: 100_000, height: 100_000)

    /// The solve panel's shared origin (bottom-left anchor offset). Dragging the
    /// panel on any canvas moves it on all of them — positional identity again.
    var solvePanelOrigin = CGPoint(x: 12, y: 28)

    // MARK: - Countdowns (the top-of-screen banner)

    /// The two safety countdowns. `.revertModes`: a whole-cast resolution change might
    /// have blacked out *every* screen, so it un-does itself unless the user says keep.
    /// `.feedGuard`: going live on a big cast might wedge the machine, so the feed cuts
    /// itself unless the user says keep. Independent — both can run at once.
    enum CountdownKind: Hashable, CaseIterable { case revertModes, feedGuard }
    struct Countdown {
        var remaining: Int
        let onExpire: () -> Void
    }

    /// Live countdowns by kind (empty ⇒ no banner). Every canvas's banner renders this.
    private(set) var countdowns: [CountdownKind: Countdown] = [:]
    private var countdownTimer: Timer?
    /// Fires whenever a countdown leaves the table for any reason (keep, act-now,
    /// expiry) — lets ArrangerWindows stand down the feed-guard watchdog.
    var onCountdownResolved: ((CountdownKind) -> Void)?

    /// Start (or restart) a countdown. `onExpire` runs exactly once, at zero or via
    /// `resolveCountdown(_:keep: false)`.
    func armCountdown(_ kind: CountdownKind, seconds: Int, onExpire: @escaping () -> Void) {
        countdowns[kind] = Countdown(remaining: seconds, onExpire: onExpire)
        if countdownTimer == nil {
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                // The timer is scheduled on the main run loop, so this is main-thread.
                MainActor.assumeIsolated { self?.tickCountdowns() }
            }
        }
        notify()
    }

    /// End a countdown early: `keep` = the user blessed the new state (just stand
    /// down); `!keep` = act now (run the expiry action immediately).
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

    /// Undo the most recent change: pop the last plane edit if there is one, else do
    /// the pending main/resolution revert.
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

    /// Whether the plane already represents `snapshot`: same displays and physical
    /// sizes, and it converts back to the same point arrangement *up to a global
    /// translation* (so a main-only change — which just re-anchors the origin — isn't
    /// treated as an external rearrange that re-interprets the plane and shuffles the
    /// tiles).
    private func planeMatches(_ snapshot: [DisplaySnapshot]) -> Bool {
        guard !plane.isEmpty, Set(snapshot.map(\.id)) == Set(plane.keys) else { return false }
        for d in snapshot {
            let ps = SchematicLayout.physSize(d)
            guard let r = plane[d.id], abs(r.width - ps.width) < 0.05, abs(r.height - ps.height) < 0.05 else { return false }
        }
        let ours = SchematicLayout.toPoints(rects: plane, displays: snapshot)
        // Compare relative to a common reference so a translation doesn't count.
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

    /// Plane displays with the effective point size applied (committed origins are fine
    /// — `toPoints`/`seamBars` ignore origins). Mirrored slaves are excluded: they have
    /// no seam and don't participate in the point arrangement.
    func sizedDisplays() -> [DisplaySnapshot] {
        planeDisplays.map { $0.with(bounds: CGRect(origin: $0.bounds.origin, size: pointSize($0))) }
    }

    /// The point-space origins for the current plane. During a drag we hold the unmoved
    /// displays frozen (`lockedSolve`); otherwise a normal full solve.
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

    /// The display macOS will put the Dock on for the arrangement currently on the plane
    /// (predicted from the reconstructed point layout, so it updates live while dragging).
    func predictedDockDisplay() -> CGDirectDisplayID? {
        // Origins come from the (possibly previewed) point sizes; the rects must use the
        // *same* sizes, or a resolution preview leaves origins and sizes inconsistent and
        // the Dock is predicted onto the wrong display.
        let sized = sizedDisplays()
        let origins = SchematicLayout.toPoints(rects: plane, displays: sized)
        var pointRects: [CGDirectDisplayID: CGRect] = [:]
        for d in sized {
            let o = origins[d.id] ?? d.bounds.origin
            pointRects[d.id] = CGRect(origin: o, size: d.bounds.size)
        }
        // During a menu-bar drag, `pendingMainID` is the would-be main, so the Dock
        // prediction moves live before the drop commits.
        let mainID = pendingMainID ?? sized.first { $0.isMain }?.id
        return DockPredictor.dockDisplay(pointRects: pointRects, mainID: mainID, edge: DockPredictor.edge())
    }

    /// The display the Dock is on *right now* in the committed OS layout (before any
    /// pending plane edit / main change). Used to decide whether the prediction differs.
    func currentDockDisplay() -> CGDirectDisplayID? {
        let mainID = pendingMainID ?? displays.first { $0.isMain }?.id
        var pointRects: [CGDirectDisplayID: CGRect] = [:]
        for d in displays { pointRects[d.id] = d.bounds }
        return DockPredictor.dockDisplay(pointRects: pointRects, mainID: mainID, edge: DockPredictor.edge())
    }

    /// The main display implied by an in-progress menu-bar drag (nil when not dragging).
    /// Set by the canvas while the menu-bar strip hovers a target tile, so the dock
    /// prediction reflects the would-be main during the drag.
    var pendingMainID: CGDirectDisplayID?

    /// The seam palette. `DisplayGraph` assigns each seam an index (pure edge-coloring);
    /// the actual colors are a presentation choice and live here.
    ///
    /// Please do not send your princess to deconversion therapy camp. See the
    /// README's "The glitz is load-bearing" before reaching for the beige.
    static let seamPalette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.41, blue: 0.71, alpha: 1),  // hot pink (the lead)
        NSColor(srgbRed: 0.64, green: 0.24, blue: 0.95, alpha: 1),  // violet (was fuchsia — too close to the pink)
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.20, alpha: 1),  // gold
        NSColor(srgbRed: 0.25, green: 0.85, blue: 0.95, alpha: 1),  // electric cyan
        NSColor(srgbRed: 0.72, green: 0.45, blue: 1.00, alpha: 1),  // lavender
        NSColor(srgbRed: 1.00, green: 0.45, blue: 0.35, alpha: 1),  // coral
        NSColor(srgbRed: 0.45, green: 0.95, blue: 0.65, alpha: 1),  // mint (range, honey)
        NSColor(srgbRed: 0.95, green: 0.20, blue: 0.30, alpha: 1),  // classic red lip
    ]

    /// Colors keyed by seam (unordered display pair), derived from the current bars so
    /// both bars of a seam — edge and mini-map — share one color, recomputed as the
    /// layout changes during a drag. Delegates to the shared `SeamColorBook` so the
    /// arranger and the always-on seam lights agree on every seam's color.
    func seamColors(_ bars: [SeamBar]) -> [DisplayGraph.SeamKey: NSColor] {
        SeamColorBook.shared.colors(for: bars.map { ($0.aID, $0.bID) })
    }

    func commit() {
        guard !plane.isEmpty else { return }
        onCommit?(SchematicLayout.toPoints(rects: plane, displays: sizedDisplays()))
    }

    /// The current plane as a point arrangement shifted so `id` sits at the origin —
    /// i.e. the arrangement with `id` made main, geometry otherwise unchanged.
    func originsMakingMain(_ id: CGDirectDisplayID) -> [CGDirectDisplayID: CGPoint]? {
        guard !plane.isEmpty else { return nil }
        let origins = SchematicLayout.toPoints(rects: plane, displays: sizedDisplays())
        guard let offset = origins[id] else { return nil }
        return origins.mapValues { CGPoint(x: $0.x - offset.x, y: $0.y - offset.y) }
    }
}

/// The app's one seam→color assignment, shared by every consumer (the arranger's bars and
/// the always-on seam lights), so a seam wears the same color everywhere it appears.
/// Remembers the last assignment and feeds it back into the edge-coloring, so a surviving
/// seam keeps its color across rebuilds instead of churning when the index order shifts.
/// (Stale entries for vanished seams are harmless — the result drops them.)
@MainActor
final class SeamColorBook {
    static let shared = SeamColorBook()

    private var last: [DisplayGraph.SeamKey: Int] = [:]

    /// The color for each seam (unordered display pair), stable across calls.
    func colors(for pairs: [(CGDirectDisplayID, CGDirectDisplayID)]) -> [DisplayGraph.SeamKey: NSColor] {
        let indices = DisplayGraph.seamColorIndices(pairs, previous: last)
        last = indices   // only surviving seams (the result drops vanished ones)
        return indices.mapValues { ArrangerState.seamPalette[$0 % ArrangerState.seamPalette.count] }
    }
}
