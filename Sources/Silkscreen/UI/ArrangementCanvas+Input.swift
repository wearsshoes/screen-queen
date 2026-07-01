import AppKit

/// Interaction: mouse dragging and keyboard nudge/align/selection. All mutate the shared
/// `state` and broadcast a redraw. (Resolution/mode handling lives in
/// ArrangementCanvas+Resolution; the context menu in ArrangementCanvas+Menu.)
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
        // Same source the ghost preview reads, so what was previewed is what applies.
        guard let o = SchematicSnapping.plannedMoves(id, plane: plane, activeV: activeV, activeH: activeH)[dir] else { return }
        plane[id] = CGRect(origin: o, size: plane[id]!.size)
        let m = SchematicSnapping.markerForJoin(id, plane: plane)
        activeV = m.v; activeH = m.h
        emitPreview()
    }

    /// The valid ⌘⇧ arrow destinations (grey-ghosted while ⌘⇧ is held) for the selected
    /// tile: each arrow's move direction and the physical rect it lands on. Reads the same
    /// `plannedMoves` map that `stepAlignment` applies from.
    func alignGhosts() -> [(dir: MoveDirection, rect: CGRect)] {
        guard let id = selectedID, let size = plane[id]?.size else { return [] }
        return SchematicSnapping.plannedMoves(id, plane: plane, activeV: activeV, activeH: activeH)
            .map { (dir, origin) in (dir, CGRect(origin: origin, size: size)) }
    }
}
