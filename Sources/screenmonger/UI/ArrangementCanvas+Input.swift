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
        // Grabbing the main tile's menu-bar strip starts a "move main" drag.
        if mainMenuBarViewRect()?.contains(p) == true { draggingMenuBar = p; needsDisplay = true; return }
        guard let d = display(at: p), plane[d.id] != nil else { return }
        draggedID = d.id
        selectedID = d.id
        dragStartMouse = p
        dragTransform = transform(plane)      // freeze so the cursor mapping is stable
        dragStartPhys = plane[d.id]?.origin ?? .zero
        dragMoved = false
        activeV = nil; activeH = nil
        emitPreview()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if draggingMenuBar != nil { draggingMenuBar = p; needsDisplay = true; return }
        guard let id = draggedID, let dragged = displays.first(where: { $0.id == id }),
              let t = dragTransform ?? transform(plane) else { return }
        // The tile tracks the cursor 1:1: view delta ÷ scale = physical delta.
        let free = CGPoint(x: dragStartPhys.x + (p.x - dragStartMouse.x) / t.scale,
                           y: dragStartPhys.y + (p.y - dragStartMouse.y) / t.scale)
        let snap = !event.modifierFlags.contains(.shift) // Shift cancels docking/snapping
        let resolved = dockAndSnap(dragged, free: free, scale: t.scale, snap: snap)
        guard resolved != plane[id]?.origin else { return }
        if !dragMoved { state.pushUndo() }   // snapshot before the drag's first move
        plane[id] = CGRect(origin: resolved, size: SchematicLayout.physSize(dragged))
        dragMoved = true
        needsDisplay = true
        emitPreview()
    }

    override func mouseUp(with event: NSEvent) {
        defer { draggedID = nil; dragMoved = false; dragTransform = nil; draggingMenuBar = nil }
        // Dropped the menu-bar strip: whichever tile it's over becomes main.
        if let p = draggingMenuBar {
            needsDisplay = true
            if let d = display(at: p), !d.isMain { onSetMain?(d.id) }
            return
        }
        guard draggedID != nil else { return }
        guard dragMoved else { needsDisplay = true; return } // click, no move: plane unchanged
        commitPlane()
    }

    /// Dock the dragged rect flush to the nearest neighbor on the plane and light-
    /// magnet its slide to a physical alignment anchor. Returns the physical origin.
    private func dockAndSnap(_ dragged: DisplaySnapshot, free: CGPoint, scale: CGFloat, snap: Bool) -> CGPoint {
        activeV = nil; activeH = nil
        let dP = SchematicLayout.physSize(dragged)
        let others = plane.filter { $0.key != dragged.id }
        guard snap, !others.isEmpty else { return free }

        // 1) Dock flush to the nearest neighbor without overlapping.
        var best = free, bestDist = CGFloat.greatestFiniteMagnitude
        var neighbor: (id: CGDirectDisplayID, rect: CGRect)?, verticalSeam = true
        for (oid, oR) in others {
            let yA = clamp(free.y, oR.minY - dP.height + 0.05, oR.maxY - 0.05)
            let xA = clamp(free.x, oR.minX - dP.width + 0.05, oR.maxX - 0.05)
            let candidates: [(CGPoint, Bool)] = [
                (CGPoint(x: oR.maxX, y: yA), true), (CGPoint(x: oR.minX - dP.width, y: yA), true),
                (CGPoint(x: xA, y: oR.maxY), false), (CGPoint(x: xA, y: oR.minY - dP.height), false),
            ]
            for (cand, vert) in candidates {
                let rect = CGRect(origin: cand, size: dP).insetBy(dx: 0.1, dy: 0.1)
                if others.contains(where: { $0.value.intersects(rect) }) { continue }
                let d = hypot(cand.x - free.x, cand.y - free.y)
                if d < bestDist { bestDist = d; best = cand; neighbor = (oid, oR); verticalSeam = vert }
            }
        }
        guard let o = neighbor else { return free }

        // 2) Magnet the slide to a physical anchor (within a few view px).
        let threshold = 5 / max(scale, 0.0001) // inches
        if verticalSeam {
            var bestD = threshold
            for s in SchematicLayout.physSnapsV(childHeight: dP.height, parent: o.rect) where abs(s.along - best.y) < bestD {
                bestD = abs(s.along - best.y); best.y = s.along; activeV = (s.selfAnchor, s.otherAnchor, o.id)
            }
        } else {
            var bestD = threshold
            for s in SchematicLayout.physSnapsH(childWidth: dP.width, parent: o.rect) where abs(s.along - best.x) < bestD {
                bestD = abs(s.along - best.x); best.x = s.along; activeH = (s.selfAnchor, s.otherAnchor, o.id)
            }
        }
        return best
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        lo <= hi ? min(max(v, lo), hi) : (lo + hi) / 2
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let cmd = flags.contains(.command), shift = flags.contains(.shift)

        // Escape / Return / ⌘Return = Done (commit & exit).
        if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76 { onDismiss?(); return }

        if cmd, let ch = event.charactersIgnoringModifiers, "+=-_0".contains(ch) {
            if !event.isARepeat { handleResolutionKey(ch) }
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
        if alignPending, !(f.contains(.command) && f.contains(.shift)) {
            alignPending = false
            emitPreview()
            commitPlane()
        }
        if zoomPending, !f.contains(.command) {
            zoomPending = false
            let mode = pendingMode
            // A resolution change leaves the physical plane untouched; commit the point
            // arrangement that reproduces it at the new size, preserving alignment.
            let origins = SchematicLayout.toPoints(rects: plane, displays: sizedDisplays())
            pendingMode = nil; pendingSize.removeAll()
            if let mode { onSetResolution?(mode.id, mode.mode, origins) }
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
        let rate: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 3.0 : 0.75 // inches / sec
        var dx: CGFloat = 0, dy: CGFloat = 0
        if heldDirections.contains(.left) { dx -= 1 }
        if heldDirections.contains(.right) { dx += 1 }
        if heldDirections.contains(.up) { dy -= 1 }   // y grows downward
        if heldDirections.contains(.down) { dy += 1 }
        nudgeAccum.x += dx * rate * dt
        nudgeAccum.y += dy * rate * dt
        // Autosolve (dock, no alignment magnet).
        plane[id] = CGRect(origin: dockAndSnap(sel, free: nudgeAccum, scale: transform(plane)?.scale ?? 1, snap: true),
                           size: SchematicLayout.physSize(sel))
        activeV = nil; activeH = nil
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

    private struct Join { let otherID: CGDirectDisplayID; let vertical: Bool; let aPositive: Bool }

    /// The selected display's current docking against a neighbor on the plane.
    private func currentJoin(_ id: CGDirectDisplayID) -> Join? {
        guard let A = plane[id] else { return nil }
        let tol: CGFloat = 0.1
        for (oid, O) in plane where oid != id {
            let yOv = min(A.maxY, O.maxY) - max(A.minY, O.minY)
            let xOv = min(A.maxX, O.maxX) - max(A.minX, O.minX)
            if abs(A.minX - O.maxX) <= tol, yOv > tol { return Join(otherID: oid, vertical: true, aPositive: true) }
            if abs(A.maxX - O.minX) <= tol, yOv > tol { return Join(otherID: oid, vertical: true, aPositive: false) }
            if abs(A.minY - O.maxY) <= tol, xOv > tol { return Join(otherID: oid, vertical: false, aPositive: true) }
            if abs(A.maxY - O.minY) <= tol, xOv > tol { return Join(otherID: oid, vertical: false, aPositive: false) }
        }
        return nil
    }

    private func stepAlignment(_ dir: MoveDirection) {
        guard let id = selectedID else { return }
        state.pushUndo()   // snapshot before each alignment step
        guard let join = currentJoin(id) else {
            // Not docked yet: dock to the nearest neighbor (a join for the next press).
            if let sel = displays.first(where: { $0.id == id }) {
                plane[id] = CGRect(origin: dockAndSnap(sel, free: plane[id]?.origin ?? .zero,
                                                       scale: transform(plane)?.scale ?? 1, snap: true),
                                   size: SchematicLayout.physSize(sel))
            }
            return
        }
        if join.vertical {
            if dir.isVertical { cycleAlign(id, other: join.otherID, vertical: true, increasing: dir == .down) }
            else if dir == (join.aPositive ? .left : .right) { redock(id, around: join.otherID, seamVertical: true) }
        } else {
            if !dir.isVertical { cycleAlign(id, other: join.otherID, vertical: false, increasing: dir == .right) }
            else if dir == (join.aPositive ? .up : .down) { redock(id, around: join.otherID, seamVertical: false) }
        }
    }

    /// Step through the seven physical alignment anchors along the seam (already in
    /// visual order), stopping at the extremes. Only the along-seam coordinate
    /// changes; the perpendicular stays flush.
    private func cycleAlign(_ id: CGDirectDisplayID, other oid: CGDirectDisplayID, vertical: Bool, increasing: Bool) {
        guard var r = plane[id], let oR = plane[oid] else { return }
        let step = increasing ? 1 : -1
        if vertical {
            let snaps = SchematicLayout.physSnapsV(childHeight: r.height, parent: oR)
            let cur = activeV?.otherID == oid
                ? (snaps.firstIndex { $0.selfAnchor == activeV!.selfA && $0.otherAnchor == activeV!.otherA } ?? nearestIndex(snaps.map(\.along), r.minY))
                : nearestIndex(snaps.map(\.along), r.minY)
            let t = snaps[max(0, min(snaps.count - 1, cur + step))]
            r.origin.y = t.along; plane[id] = r
            activeV = (t.selfAnchor, t.otherAnchor, oid); activeH = nil
        } else {
            let snaps = SchematicLayout.physSnapsH(childWidth: r.width, parent: oR)
            let cur = activeH?.otherID == oid
                ? (snaps.firstIndex { $0.selfAnchor == activeH!.selfA && $0.otherAnchor == activeH!.otherA } ?? nearestIndex(snaps.map(\.along), r.minX))
                : nearestIndex(snaps.map(\.along), r.minX)
            let t = snaps[max(0, min(snaps.count - 1, cur + step))]
            r.origin.x = t.along; plane[id] = r
            activeH = (t.selfAnchor, t.otherAnchor, oid); activeV = nil
        }
        emitPreview()
    }

    private func nearestIndex(_ values: [CGFloat], _ current: CGFloat) -> Int {
        var bestI = 0, bestD = CGFloat.greatestFiniteMagnitude
        for (i, v) in values.enumerated() where abs(v - current) < bestD { bestD = abs(v - current); bestI = i }
        return bestI
    }

    /// Re-dock onto the nearer perpendicular edge of the neighbor (centered), so
    /// alignment can "turn the corner".
    private func redock(_ id: CGDirectDisplayID, around oid: CGDirectDisplayID, seamVertical: Bool) {
        guard var r = plane[id], let O = plane[oid] else { return }
        if seamVertical {
            r.origin.x = O.midX - r.width / 2
            r.origin.y = (r.midY <= O.midY) ? (O.minY - r.height) : O.maxY
            activeH = (.center, .center, oid); activeV = nil
        } else {
            r.origin.y = O.midY - r.height / 2
            r.origin.x = (r.midX <= O.midX) ? (O.minX - r.width) : O.maxX
            activeV = (.center, .center, oid); activeH = nil
        }
        plane[id] = r
        emitPreview()
    }

    // MARK: - Resolution

    /// Step the selected display's resolution: preview via `pendingSize` (physical
    /// size is unchanged, so the plane and alignment are untouched), apply the mode
    /// when ⌘ is released.
    private func handleResolutionKey(_ ch: String) {
        guard let id = selectedID, let display = displays.first(where: { $0.id == id }) else { NSSound.beep(); return }
        let modes = modesList(for: display).sorted { $0.pointWidth * $0.pointHeight < $1.pointWidth * $1.pointHeight }
        guard !modes.isEmpty else { return }
        let currentMode = (pendingMode?.id == id ? pendingMode?.mode : nil) ?? CGDisplayCopyDisplayMode(id)
        let idx = modes.firstIndex { currentMode != nil && ModeCatalog.sameMode(currentMode!, $0.cgMode) }

        var target: DisplayMode?
        switch ch {
        case "=", "+": target = idx.map { $0 - 1 >= 0 ? modes[$0 - 1] : modes.first } ?? modes.first
        case "-", "_": target = idx.map { $0 + 1 < modes.count ? modes[$0 + 1] : modes.last } ?? modes.last
        case "0": target = defaultMode(modes)
        default: break
        }
        guard let t = target else { return }

        pendingMode = (id, t.cgMode)
        pendingSize[id] = CGSize(width: t.pointWidth, height: t.pointHeight)
        zoomPending = true
        needsDisplay = true
        emitPreview()
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
        return filtered.isEmpty ? all : filtered
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
            if displays.count > 1 {
                let matchItem = NSMenuItem(title: "Calibrate by Matching…", action: #selector(calibrateVisualFromMenu(_:)), keyEquivalent: "")
                matchItem.target = self; matchItem.representedObject = NSNumber(value: d.id)
                menu.addItem(matchItem)
            }
            let calItem = NSMenuItem(title: "Calibrate by Diagonal…", action: #selector(calibrateFromMenu(_:)), keyEquivalent: "")
            calItem.target = self; calItem.representedObject = NSNumber(value: d.id)
            menu.addItem(calItem)
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
