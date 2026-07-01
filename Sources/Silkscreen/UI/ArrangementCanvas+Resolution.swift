import AppKit

/// Resolution / display-mode *interaction*: the ⌘± single-display steps, the ⌘⇧± global
/// proportional zoom, and previewing/committing pending modes. The pure ladder math (which
/// modes to offer, ordering, default, PPI) lives in `ResolutionLadder`; the thin wrappers
/// here supply the live system facts (catalog modes, notch, current mode, pending state).
extension ArrangementCanvas {

    /// Step the selected display's resolution: preview via `pendingSize` (physical
    /// size is unchanged, so the plane and alignment are untouched), apply the mode
    /// when ⌘ is released.
    func handleResolutionKey(_ ch: String) {
        guard let id = selectedID, let display = displays.first(where: { $0.id == id }) else { NSSound.beep(); return }
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

    /// Global (⌘⇧ +/−/0) resolution zoom, keeping displays roughly proportional in PPI.
    ///
    /// A single continuous, *unclamped* `globalZoomLevel` scales every display's starting
    /// PPI; each display snaps to the achievable mode nearest `startPPI × level`, clamped
    /// to its own range. Because the level is unclamped, a display that hits its max stays
    /// pinned while the level keeps rising (others pass it), then rejoins proportionally
    /// as the level falls back — the "descend alone until ratios match" behaviour. The
    /// whole ⌘⇧-held run commits as one revertable step (one undo).
    func handleGlobalResolutionKey(_ ch: String) {
        // A fresh run (no zoom in progress): capture each display's starting PPI and reset
        // the level. `0` also resets the run and targets each display's default.
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
            if let curIdx = currentModeIndex(for: d, in: modes),
               !ModeCatalog.sameMode(modes[curIdx].cgMode, mode.cgMode) {
                anyMoved = true
            }
            targets.append((d.id, mode))
        }

        // Every display is pinned at an extreme — don't let the unclamped level drift, or
        // you'd have to unwind that phantom travel before anything moves again.
        guard !targets.isEmpty else { NSSound.beep(); return }
        guard anyMoved || ch == "0" else {
            globalZoomLevel = previousLevel
            NSSound.beep()
            return
        }

        state.pendingModes.removeAll(); pendingSize.removeAll()
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
        ResolutionLadder.currentIndex(in: modes, matching: state.pendingMode(for: d.id) ?? CGDisplayCopyDisplayMode(d.id))
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
        if replacing { state.pendingModes.removeAll(); pendingSize.removeAll() }
        state.pendingModes[id] = mode.cgMode
        pendingSize[id] = CGSize(width: mode.pointWidth, height: mode.pointHeight)
        needsDisplay = true
        emitPreview()
    }

    /// Apply the pending resolution(s): commit the point arrangement that reproduces the
    /// plane at the new size(s) (preserving alignment), then clear the preview. Commits
    /// every pending display in one batch so a multi-display zoom is a single undo.
    func commitPendingResolution() {
        zoomPending = false
        let modes = state.pendingModes
        guard !modes.isEmpty else { return }
        let origins = SchematicLayout.toPoints(rects: plane, displays: sizedDisplays())
        state.pendingModes.removeAll(); pendingSize.removeAll()
        onSetResolutions?(modes, origins)
    }

    /// Whether `d` is a notched built-in display (its screen reserves a top safe area) —
    /// a live `NSScreen` query, kept in the UI layer so `ResolutionLadder` stays pure.
    private func isNotched(_ d: DisplaySnapshot) -> Bool {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == d.id }
        return (screen?.safeAreaInsets.top ?? 0) > 0
    }
}
