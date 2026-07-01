import AppKit

/// Resolution / display-mode handling: the ⌘± single-display steps, the ⌘⇧± global
/// proportional zoom, and the mode list the slider and menu both index into. Previews
/// go through `state.pendingModes`/`pendingSize` (physical size unchanged, so the plane
/// and alignment stay put); the pending set commits as one revertable step.
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
        case "0": target = defaultMode(modes)
        default: break
        }
        guard let t = target else { return }

        previewMode(t, on: id)
        zoomPending = true
    }

    /// PPI of `mode` on `d` (points per physical inch — the density that governs how big
    /// UI looks), or nil when the physical size is unknown.
    private func modePPI(_ mode: DisplayMode, on d: DisplaySnapshot) -> Double? {
        let inches = Double(d.physicalSizeMM.width) / 25.4
        guard inches > 0.1 else { return nil }
        return Double(mode.pointWidth) / inches
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
                if let idx = currentModeIndex(for: d, in: modes), let ppi = modePPI(modes[idx], on: d) {
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
            if ch == "0", let def = defaultMode(modes) { return def }
            if let start = globalZoomStartPPI[d.id] {
                let target = start * globalZoomLevel
                return modes.min(by: {
                    abs((modePPI($0, on: d) ?? 0) - target) < abs((modePPI($1, on: d) ?? 0) - target)
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

    /// Sorted resolution modes (small → large point area) for `d`, the ordering the
    /// slider and the ⌘±/0 keys both index into.
    func sortedModes(for d: DisplaySnapshot) -> [DisplayMode] {
        modesList(for: d).sorted { $0.pointWidth * $0.pointHeight < $1.pointWidth * $1.pointHeight }
    }

    /// Index of `d`'s current (or pending) mode within `sortedModes`, if present.
    func currentModeIndex(for d: DisplaySnapshot, in modes: [DisplayMode]) -> Int? {
        let cur = state.pendingMode(for: d.id) ?? CGDisplayCopyDisplayMode(d.id)
        return modes.firstIndex { cur != nil && ModeCatalog.sameMode(cur!, $0.cgMode) }
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

    func modesList(for d: DisplaySnapshot) -> [DisplayMode] {
        let all = ModeCatalog.menuModes(for: d.id)
        guard d.isBuiltin, !extendedBuiltinModes else { return all }

        // Standard = clean 2× Retina modes.
        var filtered = all.filter { $0.pixelWidth == 2 * $0.pointWidth }
        // On a notched display also hide the "notchless" (letterboxed, shorter)
        // variants: for each width the notched mode is the tallest, so drop anything
        // shorter than the tallest at that width.
        if isNotched(d) {
            var tallest: [Int: Int] = [:]
            for m in filtered { tallest[m.pixelWidth] = max(tallest[m.pixelWidth] ?? 0, m.pixelHeight) }
            filtered = filtered.filter { $0.pixelHeight == tallest[$0.pixelWidth] }
        }
        guard !filtered.isEmpty else { return all }

        // The full clean-2× ladder runs from absurdly tiny (640×360) to native, but
        // macOS System Settings only surfaces a handful of "looks like" sizes at the
        // crisp (large) end. Match that: take the top of the ladder, so the slider/menu
        // don't step through the useless small extremes (the "Show Extended Resolutions"
        // toggle still reveals the full list). The window is *stable* — anchored at the
        // native end, not the moving current mode — so the menu and slider always agree.
        let sorted = filtered.sorted { $0.pointWidth * $0.pointHeight < $1.pointWidth * $1.pointHeight }
        var lo = max(0, sorted.count - 5)   // macOS surfaces ~5 crisp "looks like" sizes
        // Always include the current mode, even if it's been set below the crisp band,
        // so the slider knob and the menu checkmark land on a real entry.
        if let cur = CGDisplayCopyDisplayMode(d.id),
           let curIdx = sorted.firstIndex(where: { ModeCatalog.sameMode(cur, $0.cgMode) }) {
            lo = min(lo, curIdx)
        }
        return Array(sorted[lo...])
    }

    /// Whether `d` is a notched built-in display (its screen reserves a top safe area).
    private func isNotched(_ d: DisplaySnapshot) -> Bool {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == d.id }
        return (screen?.safeAreaInsets.top ?? 0) > 0
    }

    private func defaultMode(_ modes: [DisplayMode]) -> DisplayMode? {
        let retina = modes.filter { abs($0.pixelWidth - 2 * $0.pointWidth) <= 1 }
        return (retina.isEmpty ? modes : retina).max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
    }
}
