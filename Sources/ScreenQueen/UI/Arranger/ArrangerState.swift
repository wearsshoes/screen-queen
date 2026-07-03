import CoreGraphics
import Foundation
import Observation

/// The editing state shared by every per-screen `Stage`: the physical plane plus
/// selection/preview state and app callbacks. A mutation on any stage writes here;
/// SwiftUI islands whose body reads this state repaint via Observation, and
/// `changed()` still fans out to the AppKit-side work (frames, layers, the schematic).
@Observable @MainActor
final class ArrangerState {

    /// The app-level executor for every display command (set once by the AppDelegate) —
    /// one reference instead of a closure per command.
    @ObservationIgnored weak var commander: (any DisplayCommanding)?

    /// Resolution-slider drag began/ended — Arranger drives the ghost aids from a
    /// timer while held (the modal tracking loop starves the mouse monitors).
    @ObservationIgnored var onSliderDragChanged: ((Bool) -> Void)?

    /// Called after any mutation so every stage redraws.
    @ObservationIgnored var changed: (() -> Void)?

    var displays: [DisplaySnapshot] = []
    var selectedID: CGDirectDisplayID?

    /// Live per-display screen capture (nil when unavailable / not started).
    @ObservationIgnored var capture: ScreenCaptureManager?

    /// Whether the live video feed is on (tiles show live content vs. static wallpaper).
    var feedEnabled = false
    @ObservationIgnored var onToggleFeed: ((Bool) -> Void)?

    /// A live macOS-managed AirPlay visual session (nil when none) — detected via a
    /// power assertion, so it catches even the "Window or App" mode with no display ID.
    var airplaySession: AirPlaySession?

    /// The physical plane (inches) — the source of truth while manipulating.
    /// External writes go through `setPlaneRect` so mutations are named and the
    /// state can adopt @Observable without hunting down pokes.
    private(set) var plane: [CGDirectDisplayID: CGRect] = [:]

    /// Move/resize one display's plane rect — the drag / nudge / alignment mutation.
    func setPlaneRect(_ rect: CGRect, for id: CGDirectDisplayID) { plane[id] = rect }

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

    /// Resolution preview (pending until ⌘ released) — one entry in `.one` scope, many
    /// in `.all`. The previewed point size is the mode's own (see `pointSize`); there is
    /// no second copy to drift.
    var pendingModes: [CGDirectDisplayID: DisplayMode] = [:]

    /// The previewed mode for `id`, if any.
    func pendingMode(for id: CGDirectDisplayID) -> DisplayMode? { pendingModes[id] }

    /// Whether the resolution slider drives one display or all of them proportionally.
    enum SliderScope { case one, all }
    var sliderScope: SliderScope = .one

    /// Active alignment anchors, for the tile arrow markers (V = vertical seam active).
    var activeV: AnchorMarker?
    var activeH: AnchorMarker?

    /// "Show the Full Wardrobe": reveal extended/off-native-aspect modes. Persisted.
    static let extendedModesKey = "showFullWardrobe"
    var extendedBuiltinModes = UserDefaults.standard.bool(forKey: ArrangerState.extendedModesKey) {
        didSet { UserDefaults.standard.set(extendedBuiltinModes, forKey: Self.extendedModesKey) }
    }

    /// True while ⌘⇧ is held: every stage ghosts the possible alignment destinations.
    var showAlignGhosts = false

    /// A pending revert for the last main/resolution change (nil ⇒ none). Applied by
    /// Undo once the plane-edit stack is exhausted; set by the AppDelegate.
    @ObservationIgnored var pendingRevert: (() -> Void)?

    // MARK: - Chrome anchor space (unified across screens)

    /// Unified chrome metrics: the largest Dock / menu-bar claim anywhere and the
    /// smallest screen extents, identical on every stage so chrome placed within them
    /// is in-bounds everywhere. Recomputed by Arranger on every rebuild.
    var uniformDockInset: CGFloat = 0
    var uniformMenuBarInset: CGFloat = 0
    var minScreenExtent = CGSize(width: 100_000, height: 100_000)

    /// The granny panel's centre as an offset from the screen centre, in **plane
    /// inches** — its own state (moving a tile never moves it), scaling with the
    /// minimap. A drag on any stage moves it on all of them.
    var solvePanelCenterOffsetInches = CGPoint(x: -5, y: 4)   // lower-left of centre (+y down)

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
    @ObservationIgnored private var countdownTimer: Timer?
    /// Fires whenever a countdown leaves the table for any reason (keep, act-now, expiry).
    @ObservationIgnored var onCountdownResolved: ((CountdownKind) -> Void)?

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
        pendingModes.removeAll()
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
                  abs((o.x - ox) - d.bounds.minX) < Tol.planeMatch, abs((o.y - oy) - d.bounds.minY) < Tol.planeMatch else { return false }
        }
        return true
    }

    /// Effective point size (live during a zoom preview).
    func pointSize(_ d: DisplaySnapshot) -> CGSize {
        pendingModes[d.id].map { CGSize(width: $0.pointWidth, height: $0.pointHeight) } ?? d.bounds.size
    }

    /// Points per physical inch at the effective point size — the density readout the
    /// label cards and mirror cards show. nil when the physical size is unknown.
    func effectivePPI(_ d: DisplaySnapshot) -> Double? {
        let sz = pointSize(d)
        guard d.diagonalInches > 0, sz.width > 0 else { return nil }
        return Double(sz.width) / (Double(d.physicalSizeMM.width) / 25.4)
    }

    /// The stat strings the label card and the mirror card share: "W×H( HiDPI)" and
    /// "NN″ · NN ppi" — or the calibrate prompt when she won't say her size, on both
    /// cards (a mirrored girl can lie about her size too).
    func statLines(for d: DisplaySnapshot) -> (resolution: String, detail: String) {
        let sz = pointSize(d)
        let pixelW = pendingModes[d.id]?.pixelWidth ?? Int(d.pixelSize.width)
        let hidpi = pixelW > Int(sz.width) ? " HiDPI" : ""
        let resolution = "\(Int(sz.width))×\(Int(sz.height))" + hidpi
        let diag = d.diagonalInches > 0 ? String(format: "%.0f″ · ", d.diagonalInches) : ""
        let detail = effectivePPI(d).map { diag + String(format: "%.0f ppi", $0) }
            ?? (diag + Copy.calibratePrompt)
        return (resolution, detail)
    }

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

    func currentBars(origins: [CGDirectDisplayID: CGPoint]? = nil) -> [SeamBar] {
        SchematicLayout.seamBars(sizedDisplays(), rects: plane, origins: origins ?? pointOrigins())
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

    func commit() {
        guard !plane.isEmpty else { return }
        commander?.commitArrangement(SchematicLayout.toPoints(rects: plane, displays: sizedDisplays()))
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
