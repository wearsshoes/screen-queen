import AppKit

/// Interaction: mouse dragging, keyboard nudge/align/resolution, and the tile
/// context menu. All mutate the shared `state` and broadcast a redraw.
extension ArrangementCanvas {

    // MARK: - Mouse / dragging

    func display(at p: CGPoint) -> DisplaySnapshot? {
        let rects = currentRects()
        guard let t = transform(rects) else { return nil }
        return displays.reversed().first { rects[$0.id].map { t.viewRect($0).contains(p) } ?? false }
    }

    /// The main display's menu-bar strip in view coordinates, if it's on-screen.
    private func mainMenuBarViewRect() -> NSRect? {
        guard let main = displays.first(where: { $0.isMain }), let r = plane[main.id],
              let t = dragTransform ?? transform(plane) else { return nil }
        return menuBarRect(inTile: t.viewRect(r).insetBy(dx: 1.5, dy: 1.5))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)   // focus this screen's arranger
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        // Clicking a mirror card's un-mirror button returns that display to the plane.
        if let id = unmirrorButtonRects.first(where: { $0.value.contains(p) })?.key {
            onUnmirror?(id); return
        }
        // The AirPlay card's "Open Settings" button hands off to Screen Mirroring.
        if airplaySettingsButtonRect?.contains(p) == true {
            onOpenAirPlaySettings?(); return
        }
        // Grabbing the main tile's menu-bar strip starts a "move main" drag. The Dock
        // indicator appears immediately (grabbing signals intent to move main); until the
        // cursor is over another tile the would-be main stays the current one.
        if mainMenuBarViewRect()?.contains(p) == true {
            draggingMenuBar = p
            state.pendingMainID = displays.first { $0.isMain }?.id
            state.notify()   // repaint every canvas so the Dock indicator shows everywhere
            return
        }
        guard let d = display(at: p), plane[d.id] != nil else { return }
        draggedID = d.id
        selectedID = d.id
        // Option-drag mirrors: dropping onto another tile mirrors this display onto it.
        optionMirrorDrag = event.modifierFlags.contains(.option) && planeDisplays.count > 1
        state.draggingDisplayID = d.id   // brighten the grabbed display's screen from click
        dragStartMouse = p
        dragTransform = transform(plane)      // freeze so the cursor mapping is stable
        dragStartPhys = plane[d.id]?.origin ?? .zero
        dragMoved = false
        activeV = nil; activeH = nil
        emitPreview()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if draggingMenuBar != nil {
            draggingMenuBar = p
            // Would-be main = the tile under the cursor (else the current main), so the
            // Dock prediction follows the strip live during the drag.
            let over = display(at: p)
            state.pendingMainID = over?.id ?? displays.first { $0.isMain }?.id
            state.notify()
            return
        }
        // Option-mirror drag: don't move the plane; just track the cursor for the drop
        // target and highlight the tile under it (drawn like the menu-bar drop hint).
        if optionMirrorDrag { mirrorDragPoint = p; dragMoved = true; needsDisplay = true; return }
        guard let id = draggedID, let dragged = displays.first(where: { $0.id == id }),
              let t = dragTransform ?? transform(plane) else { return }
        // The tile tracks the cursor 1:1: view delta ÷ scale = physical delta. The view is
        // y-up but the physical plane is y-down (`CGDisplayBounds`), so the y delta inverts.
        let free = CGPoint(x: dragStartPhys.x + (p.x - dragStartMouse.x) / t.scale,
                           y: dragStartPhys.y - (p.y - dragStartMouse.y) / t.scale)
        let snap = SchematicSnapping.dockAndSnap(dragged: SchematicLayout.physSize(dragged), id: id,
                                                 free: free, scale: t.scale, snap: true, plane: plane)
        activeV = snap.activeV; activeH = snap.activeH
        guard snap.origin != plane[id]?.origin else { return }
        if !dragMoved { state.pushUndo() }   // snapshot before the drag's first move
        plane[id] = CGRect(origin: snap.origin, size: SchematicLayout.physSize(dragged))
        dragMoved = true
        needsDisplay = true
        emitPreview()
    }

    override func mouseUp(with event: NSEvent) {
        defer { draggedID = nil; dragMoved = false; dragTransform = nil; draggingMenuBar = nil
                optionMirrorDrag = false; mirrorDragPoint = nil; state.pendingMainID = nil
                state.draggingDisplayID = nil; state.notify() }
        // Dropped the menu-bar strip: whichever tile it's over becomes main.
        if let p = draggingMenuBar {
            needsDisplay = true
            if let d = display(at: p), !d.isMain { onSetMain?(d.id) }
            return
        }
        // Option-mirror drop: if released over a *different* plane tile, mirror the
        // dragged display (slave) onto that tile (master).
        if optionMirrorDrag, let slave = draggedID {
            mirrorDragPoint = nil
            if let target = display(at: convert(event.locationInWindow, from: nil)),
               target.id != slave { onSetMirror?(slave, target.id) }
            needsDisplay = true
            return
        }
        guard draggedID != nil else { return }
        guard dragMoved else { needsDisplay = true; return } // click, no move: plane unchanged
        commitPlane()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let cmd = flags.contains(.command), shift = flags.contains(.shift)

        // Escape / Return / ⌘Return = Done (commit & exit).
        if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76 { onDismiss?(); return }

        if cmd, let ch = event.charactersIgnoringModifiers, "+=-_0".contains(ch) {
            if !event.isARepeat {
                if shift { handleGlobalResolutionKey(ch) } else { handleResolutionKey(ch) }
            }
            return
        }
        guard let dir = direction(event) else { super.keyDown(with: event); return }

        if cmd && shift {
            guard !event.isARepeat else { return }
            guard selectedID != nil else { NSSound.beep(); return }
            stepAlignment(dir)
            alignPending = true
            emitPreview()
        } else if cmd {
            moveSelection(dir)
        } else {
            guard selectedID != nil else { NSSound.beep(); return }
            beginContinuousMoveIfNeeded()
            heldDirections.insert(dir)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let dir = direction(event) else { return }
        if heldDirections.remove(dir) != nil, heldDirections.isEmpty {
            stopMoveTimer()
            commitPlane()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let f = event.modifierFlags
        // Ghost the possible ⌘⇧ alignment destinations while ⌘⇧ is held — on every
        // display, so broadcast the shared flag.
        let ghosts = f.contains(.command) && f.contains(.shift) && selectedID != nil && !zoomPending
        if ghosts != showAlignGhosts { showAlignGhosts = ghosts; emitPreview() }
        if alignPending, !(f.contains(.command) && f.contains(.shift)) {
            alignPending = false
            emitPreview()
            commitPlane()
        }
        if zoomPending, !f.contains(.command) {
            // A resolution change leaves the physical plane untouched; commit the point
            // arrangement that reproduces it at the new size, preserving alignment.
            commitPendingResolution()
        }
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        if moveTimer != nil { stopMoveTimer(); commitPlane() }
        if alignPending { alignPending = false; commitPlane() }
        return super.resignFirstResponder()
    }

    private func direction(_ e: NSEvent) -> MoveDirection? {
        switch e.keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "w": return .up
        case "a": return .left
        case "s": return .down
        case "d": return .right
        default: return nil
        }
    }

    // MARK: - Nudge (continuous physical move)

    private func beginContinuousMoveIfNeeded() {
        guard moveTimer == nil, let id = selectedID else { return }
        state.pushUndo()   // snapshot before a nudge run
        nudgeAccum = plane[id]?.origin ?? .zero
        activeV = nil; activeH = nil
        lastTick = CACurrentMediaTime()
        moveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.moveTick()
        }
    }

    private func stopMoveTimer() { moveTimer?.invalidate(); moveTimer = nil }

    private func moveTick() {
        guard let id = selectedID, !heldDirections.isEmpty,
              let sel = displays.first(where: { $0.id == id }) else { stopMoveTimer(); return }
        let now = CACurrentMediaTime(), dt = CGFloat(now - lastTick); lastTick = now
        let rate: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 6.0 : 1.5 // inches / sec
        var dx: CGFloat = 0, dy: CGFloat = 0
        if heldDirections.contains(.left) { dx -= 1 }
        if heldDirections.contains(.right) { dx += 1 }
        if heldDirections.contains(.up) { dy -= 1 }   // y grows downward
        if heldDirections.contains(.down) { dy += 1 }
        nudgeAccum.x += dx * rate * dt
        nudgeAccum.y += dy * rate * dt
        // Dock + magnet to an anchor; the magnet sets activeV/H so the snapping
        // triangles show while nudging.
        let snap = SchematicSnapping.dockAndSnap(dragged: SchematicLayout.physSize(sel), id: id,
                                                 free: nudgeAccum, scale: transform(plane)?.scale ?? 1,
                                                 snap: true, plane: plane)
        activeV = snap.activeV; activeH = snap.activeH
        plane[id] = CGRect(origin: snap.origin, size: SchematicLayout.physSize(sel))
        needsDisplay = true
        emitPreview()
    }

    // MARK: - Selection

    private func center(of id: CGDirectDisplayID) -> CGPoint {
        let r = currentRects()[id] ?? .zero
        return CGPoint(x: r.midX, y: r.midY)
    }

    private func moveSelection(_ dir: MoveDirection) {
        guard let cur = selectedID ?? displays.first?.id else { return }
        let c = center(of: cur)
        let candidates = displays.filter { $0.id != cur }.filter {
            let oc = center(of: $0.id)
            switch dir {
            case .left: return oc.x < c.x - 0.01
            case .right: return oc.x > c.x + 0.01
            case .up: return oc.y < c.y - 0.01
            case .down: return oc.y > c.y + 0.01
            }
        }
        if let best = candidates.min(by: {
            hypot(center(of: $0.id).x - c.x, center(of: $0.id).y - c.y)
                < hypot(center(of: $1.id).x - c.x, center(of: $1.id).y - c.y)
        }) {
            selectedID = best.id
            activeV = nil; activeH = nil
            emitPreview()
        }
    }

    // MARK: - Keyboard alignment (physical)

    /// Apply one ⌘⇧ alignment step to the selected tile, delegating the plane geometry to
    /// `SchematicSnapping` and applying the resulting origin + markers here.
    private func stepAlignment(_ dir: MoveDirection) {
        guard let id = selectedID else { return }
        state.pushUndo()   // snapshot before each alignment step
        guard SchematicSnapping.currentJoin(id, plane: plane) != nil else {
            // Not docked yet: dock to the nearest neighbor (a join for the next press).
            if let sel = displays.first(where: { $0.id == id }) {
                let snap = SchematicSnapping.dockAndSnap(dragged: SchematicLayout.physSize(sel), id: id,
                                                         free: plane[id]?.origin ?? .zero,
                                                         scale: transform(plane)?.scale ?? 1, snap: true, plane: plane)
                activeV = snap.activeV; activeH = snap.activeH
                plane[id] = CGRect(origin: snap.origin, size: SchematicLayout.physSize(sel))
            }
            emitPreview()
            return
        }
        guard let o = SchematicSnapping.plannedOrigin(id, dir, plane: plane, activeV: activeV, activeH: activeH) else { return }
        plane[id] = CGRect(origin: o, size: plane[id]!.size)
        let m = SchematicSnapping.markerForJoin(id, plane: plane)
        activeV = m.v; activeH = m.h
        emitPreview()
    }

    /// The valid ⌘⇧ arrow destinations (grey-ghosted while ⌘⇧ is held) for the
    /// selected tile: each arrow's move direction and the physical rect it lands on
    /// (skipping no-ops).
    func alignGhosts() -> [(dir: MoveDirection, rect: CGRect)] {
        guard let id = selectedID, let size = plane[id]?.size,
              SchematicSnapping.currentJoin(id, plane: plane) != nil else { return [] }
        return [MoveDirection.up, .down, .left, .right]
            .compactMap { d in
                SchematicSnapping.plannedOrigin(id, d, plane: plane, activeV: activeV, activeH: activeH)
                    .map { (d, CGRect(origin: $0, size: size)) }
            }
    }

    // MARK: - Resolution

    /// Step the selected display's resolution: preview via `pendingSize` (physical
    /// size is unchanged, so the plane and alignment are untouched), apply the mode
    /// when ⌘ is released.
    private func handleResolutionKey(_ ch: String) {
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
    private func handleGlobalResolutionKey(_ ch: String) {
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

    private func modesList(for d: DisplaySnapshot) -> [DisplayMode] {
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

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let d = display(at: p) else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: d.name, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(resolutionMenuItem(for: d))
        // The built-in display's EDID physical size is authoritative, so it's not
        // calibratable — offer no size overrides for it.
        if !d.isBuiltin {
            menu.addItem(.separator())
            let calItem = NSMenuItem(title: "Input Size…", action: #selector(calibrateFromMenu(_:)), keyEquivalent: "")
            calItem.target = self; calItem.representedObject = NSNumber(value: d.id)
            menu.addItem(calItem)
            if displays.count > 1 {
                let matchItem = NSMenuItem(title: "Manual Calibration…", action: #selector(calibrateVisualFromMenu(_:)), keyEquivalent: "")
                matchItem.target = self; matchItem.representedObject = NSNumber(value: d.id)
                menu.addItem(matchItem)
            }
            if d.physicalSizeIsCalibrated {
                let resetItem = NSMenuItem(title: "Reset Size to EDID", action: #selector(resetCalibrationFromMenu(_:)), keyEquivalent: "")
                resetItem.target = self; resetItem.representedObject = NSNumber(value: d.id)
                menu.addItem(resetItem)
            }
        }
        return menu
    }

    private func resolutionMenuItem(for d: DisplaySnapshot) -> NSMenuItem {
        let item = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = CGDisplayCopyDisplayMode(d.id)
        for mode in modesList(for: d) {
            let mi = NSMenuItem(title: mode.label, action: #selector(setModeFromMenu(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = ModeChoice(id: d.id, mode: mode.cgMode)
            if let current, ModeCatalog.sameMode(current, mode.cgMode) { mi.state = .on }
            submenu.addItem(mi)
        }
        // The built-in normally lists only its standard (2×) modes; let the user opt
        // into the full extended set here, on its own tile.
        if d.isBuiltin {
            submenu.addItem(.separator())
            let ext = NSMenuItem(title: "Show Extended Resolutions", action: #selector(toggleExtendedBuiltin(_:)), keyEquivalent: "")
            ext.target = self; ext.state = extendedBuiltinModes ? .on : .off
            submenu.addItem(ext)
        }
        item.submenu = submenu
        return item
    }

    @objc private func toggleExtendedBuiltin(_ s: NSMenuItem) {
        extendedBuiltinModes.toggle()
        emitPreview()
    }

    private final class ModeChoice {
        let id: CGDirectDisplayID; let mode: CGDisplayMode
        init(id: CGDirectDisplayID, mode: CGDisplayMode) { self.id = id; self.mode = mode }
    }

    @objc private func setModeFromMenu(_ s: NSMenuItem) {
        guard let c = s.representedObject as? ModeChoice else { return }
        let size = CGSize(width: CGFloat(c.mode.width), height: CGFloat(c.mode.height)) // "Looks like" points
        let ds = displays.map { $0.id == c.id ? $0.with(bounds: CGRect(origin: $0.bounds.origin, size: size)) : $0 }
        onSetResolution?(c.id, c.mode, SchematicLayout.toPoints(rects: plane, displays: ds))
    }
    @objc private func calibrateFromMenu(_ s: NSMenuItem) { (s.representedObject as? NSNumber).map { onCalibrate?($0.uint32Value) } }
    @objc private func calibrateVisualFromMenu(_ s: NSMenuItem) { (s.representedObject as? NSNumber).map { onCalibrateVisual?($0.uint32Value) } }
    @objc private func resetCalibrationFromMenu(_ s: NSMenuItem) { (s.representedObject as? NSNumber).map { onResetCalibration?($0.uint32Value) } }
}
