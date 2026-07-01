import AppKit

/// The editing state shared by every per-screen `ArrangementCanvas`: one physical
/// plane and the surrounding selection/preview state, plus the app callbacks. A
/// mutation on any canvas writes here and calls `changed()` so all canvases redraw
/// from the same source of truth.
@MainActor
final class ArrangementState {

    // App callbacks (wired once by the AppDelegate).
    var onCommit: (([CGDirectDisplayID: CGPoint]) -> Void)?
    /// Set the main display (dragging the menu-bar strip onto another tile).
    var onSetMain: ((CGDirectDisplayID) -> Void)?
    var onSetResolution: ((CGDirectDisplayID, CGDisplayMode, [CGDirectDisplayID: CGPoint]) -> Void)?
    var onCalibrate: ((CGDirectDisplayID) -> Void)?
    var onCalibrateVisual: ((CGDirectDisplayID) -> Void)?
    var onResetCalibration: ((CGDirectDisplayID) -> Void)?
    var onDismiss: (() -> Void)?
    /// Restore everything to the state captured when the arranger was opened.
    var onReset: (() -> Void)?

    /// Called after any mutation so every canvas redraws.
    var changed: (() -> Void)?

    var displays: [DisplaySnapshot] = []
    var colorFor: [CGDirectDisplayID: NSColor] = [:]
    var selectedID: CGDirectDisplayID?

    /// The physical plane (inches) — the source of truth while manipulating.
    var plane: [CGDirectDisplayID: CGRect] = [:]

    /// Resolution preview (pending until ⌘ released).
    var pendingSize: [CGDirectDisplayID: CGSize] = [:]
    var pendingMode: (id: CGDirectDisplayID, mode: CGDisplayMode)?

    /// Active alignment anchors, for the tile arrow markers.
    var activeV: (selfA: VAnchor, otherA: VAnchor, otherID: CGDirectDisplayID)?
    var activeH: (selfA: HAnchor, otherA: HAnchor, otherID: CGDirectDisplayID)?

    var extendedBuiltinModes = false

    /// True while ⌘⇧ is held: every canvas ghosts the possible alignment destinations.
    var showAlignGhosts = false

    /// A pending revert for the last main/resolution change (nil ⇒ none). Applied by
    /// Undo once the plane-edit stack is exhausted; set by the AppDelegate.
    var pendingRevert: (() -> Void)?

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
            revert()
            notify()
        }
    }

    // MARK: - Interpret / commit

    func update(with displays: [DisplaySnapshot], colors: [CGDirectDisplayID: NSColor], force: Bool = false) {
        self.displays = displays
        self.colorFor = colors
        if force || !planeMatches(displays) { plane = SchematicLayout.toPlane(displays) }
        pendingSize.removeAll()
        pendingMode = nil
        if let sel = selectedID, !displays.contains(where: { $0.id == sel }) {
            selectedID = nil; activeV = nil; activeH = nil
        }
        if selectedID == nil {
            selectedID = displays.first(where: { $0.isMain })?.id ?? displays.first?.id
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

    /// Displays with the effective point size applied (committed origins are fine —
    /// `toPoints`/`seamBars` ignore origins).
    func sizedDisplays() -> [DisplaySnapshot] {
        displays.map { $0.with(bounds: CGRect(origin: $0.bounds.origin, size: pointSize($0))) }
    }

    func currentBars() -> [SeamBar] { SchematicLayout.seamBars(sizedDisplays(), rects: plane) }

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
