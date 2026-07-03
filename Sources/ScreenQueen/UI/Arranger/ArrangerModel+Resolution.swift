import CoreGraphics
import Foundation

/// Resolution / display-mode *interaction*: the ⌘± single-display steps, the ⌘⇧± global
/// proportional zoom, the bar slider's detents, and previewing/committing pending modes.
/// Model logic, not view logic — a run started from one screen's keyboard or slider
/// continues correctly wherever focus lands. The pure ladder math (which modes to offer,
/// ordering, default, PPI) lives in `ResolutionLadder`; the thin wrappers here supply the
/// live system facts (catalog modes, notch, current mode, pending state).
extension ArrangerModel {

    /// Step the selected display's resolution: preview via `pendingModes` (physical
    /// size is unchanged, so the plane and alignment are untouched), apply the mode
    /// when ⌘ is released.
    func handleResolutionKey(_ ch: String) {
        guard let id = selectedID, let display = displays.first(where: { $0.id == id }) else { Chime.beep(); return }
        let modes = sortedModes(for: display)
        guard !modes.isEmpty else { return }
        let idx = currentModeIndex(for: display, in: modes)

        var target: DisplayMode?
        switch ch {
        case "=", "+": target = idx.map { $0 - 1 >= 0 ? modes[$0 - 1] : modes.first } ?? modes.first
        case "-", "_": target = idx.map { $0 + 1 < modes.count ? modes[$0 + 1] : modes.last } ?? modes.last
        case "0": target = ResolutionLadder.defaultMode(modes)
        default: break
        }
        guard let t = target else { return }

        previewMode(t, on: id)
        zoomPending = true
    }

    /// Global (⌘⇧ +/−/0) resolution zoom: an *unclamped* level scales every display's
    /// starting PPI, each snapping to its nearest achievable mode — so a maxed-out
    /// display stays pinned while the level rises and rejoins proportionally as it
    /// falls. The whole run commits as one undo.
    func handleGlobalResolutionKey(_ ch: String) {
        // Fresh run: capture starting PPIs and reset the level.
        if !zoomPending {
            globalZoomLevel = 1
            globalZoomStartPPI.removeAll()
            for d in displays where !d.isMirrored {
                let modes = sortedModes(for: d)
                if let idx = currentModeIndex(for: d, in: modes),
                   let ppi = ResolutionLadder.ppi(modes[idx], physicalWidthMM: d.physicalSizeMM.width) {
                    globalZoomStartPPI[d.id] = ppi
                }
            }
        }

        let previousLevel = globalZoomLevel
        switch ch {
        case "=", "+": globalZoomLevel *= 1.12   // ↑ resolution (denser → smaller UI)
        case "-", "_": globalZoomLevel /= 1.12
        case "0":      globalZoomLevel = 1        // back to each display's starting level
        default: return
        }

        // Resolve the target mode each display would take at the new level.
        func targetMode(for d: DisplaySnapshot, modes: [DisplayMode]) -> DisplayMode {
            if ch == "0", let def = ResolutionLadder.defaultMode(modes) { return def }
            if let start = globalZoomStartPPI[d.id] {
                let target = start * globalZoomLevel
                return modes.min(by: {
                    let a = ResolutionLadder.ppi($0, physicalWidthMM: d.physicalSizeMM.width) ?? 0
                    let b = ResolutionLadder.ppi($1, physicalWidthMM: d.physicalSizeMM.width) ?? 0
                    return abs(a - target) < abs(b - target)
                }) ?? modes[modes.count / 2]
            }
            // No PPI (uncalibrated): fall back to a plain detent step from the current mode.
            let cur = currentModeIndex(for: d, in: modes) ?? 0
            let s = ch == "-" || ch == "_" ? 1 : -1
            return modes[max(0, min(modes.count - 1, cur + s))]
        }

        var targets: [(CGDirectDisplayID, DisplayMode)] = []
        var anyMoved = false
        for d in displays where !d.isMirrored {
            let modes = sortedModes(for: d)
            guard modes.count > 1 else { continue }
            let mode = targetMode(for: d, modes: modes)
            // Did this display actually change from its current/previewed mode?
            if let curIdx = currentModeIndex(for: d, in: modes), modes[curIdx] != mode {
                anyMoved = true
            }
            targets.append((d.id, mode))
        }

        // If nothing moved, don't let the unclamped level drift — you'd have to unwind
        // that phantom travel before anything moves again.
        guard !targets.isEmpty else { Chime.beep(); return }
        guard anyMoved || ch == "0" else {
            globalZoomLevel = previousLevel
            Chime.beep()
            return
        }

        pendingModes.removeAll()
        for (id, mode) in targets { previewMode(mode, on: id, replacing: false) }
        zoomPending = true
    }

    /// Sorted resolution modes (small → large point area) for `d` — the live-system wrapper
    /// around `ResolutionLadder`, supplying the catalog modes, notch flag, and current mode.
    func sortedModes(for d: DisplaySnapshot) -> [DisplayMode] {
        ResolutionLadder.sortedModes(all: ModeCatalog.menuModes(for: d.id), isBuiltin: d.isBuiltin,
                                     notched: isNotched(d), extended: extendedBuiltinModes,
                                     current: CGDisplayCopyDisplayMode(d.id))
    }

    /// Index of `d`'s current (or pending) mode within `sortedModes`, if present.
    func currentModeIndex(for d: DisplaySnapshot, in modes: [DisplayMode]) -> Int? {
        let key = pendingMode(for: d.id)?.key ?? CGDisplayCopyDisplayMode(d.id).map(ModeKey.init)
        return key.flatMap { k in modes.firstIndex { $0.key == k } }
    }

    /// The modes to *list* for `d` (menu order isn't sorted-by-area; the menu uses this
    /// directly). Live-system wrapper around `ResolutionLadder.modesList`.
    func modesList(for d: DisplaySnapshot) -> [DisplayMode] {
        ResolutionLadder.modesList(all: ModeCatalog.menuModes(for: d.id), isBuiltin: d.isBuiltin,
                                   notched: isNotched(d), extended: extendedBuiltinModes,
                                   current: CGDisplayCopyDisplayMode(d.id))
    }

    /// Preview `mode` on `id` (physical size unchanged, so the plane and alignment are
    /// untouched). `replacing: true` (default) clears any other pending preview — the
    /// single-display path (⌘± keys, `.one` slider); `false` adds to the set for the
    /// `.all` slider, which previews several displays at once.
    func previewMode(_ mode: DisplayMode, on id: CGDirectDisplayID, replacing: Bool = true) {
        if replacing { pendingModes.removeAll() }
        pendingModes[id] = mode
        notify()
    }

    /// Apply the pending resolution(s): commit the point arrangement that reproduces the
    /// plane at the new size(s) (preserving alignment), then clear the preview. Commits
    /// every pending display in one batch so a multi-display zoom is a single undo.
    func commitPendingResolution() {
        zoomPending = false
        let modes = pendingModes
        guard !modes.isEmpty else { return }
        let origins = SchematicLayout.toPoints(rects: plane, displays: sizedDisplays())
        pendingModes.removeAll()
        commander?.setResolutions(modes.mapValues(\.cgMode), origins)
    }

    // MARK: - The bar slider (preview as it moves, commit on release)

    /// Live-preview resolution as the slider moves (one display, or all by the same step
    /// delta): snap the raw 0…1 position to a detent, preview, commit on release.
    func sliderChanged(_ raw: Double) {
        guard let id = selectedID, sliderModes.count > 1 else { return }
        let n = sliderModes.count
        let idx = max(0, min(n - 1, Int((Double(n - 1) * raw).rounded())))

        if sliderDragStartIndex == nil {
            sliderDragStartIndex = currentModeIndex(for: displays.first { $0.id == id }!, in: sliderModes)
            onSliderDragChanged?(true)    // drive the ghost aids while held
        }

        switch sliderScope {
        case .one:
            previewMode(sliderModes[idx], on: id)
        case .all:
            let delta = idx - (sliderDragStartIndex ?? idx)
            previewProportional(stepDelta: delta)
        }
    }

    func sliderEnded() {
        guard sliderDragStartIndex != nil else { return }
        commitPendingResolution()
        sliderDragStartIndex = nil
        onSliderDragChanged?(false)
    }

    /// Preview every display shifted by `stepDelta` detents from its current mode
    /// (clamped per display), for `.all` scope.
    private func previewProportional(stepDelta: Int) {
        pendingModes.removeAll()
        for d in displays where !d.isMirrored {
            let modes = sortedModes(for: d)
            guard modes.count > 1, let base = currentModeIndex(for: d, in: modes) else { continue }
            let target = max(0, min(modes.count - 1, base + stepDelta))
            previewMode(modes[target], on: d.id, replacing: false)
        }
        notify()
    }

    /// Whether `d` is a notched built-in display — the live screen query lives in
    /// DisplayManager so this file stays AppKit-free; `ResolutionLadder` stays pure.
    private func isNotched(_ d: DisplaySnapshot) -> Bool {
        DisplayManager.isNotched(d.id)
    }
}
