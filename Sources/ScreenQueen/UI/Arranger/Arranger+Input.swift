import CoreGraphics
import Foundation

/// A key event, decoded at the routing boundary (ArrangerWindows) so this file never
/// touches NSEvent — the handlers speak plain values.
struct KeyInput {
    var code: UInt16
    var chars: String?
    var cmd: Bool
    var shift: Bool
    var isRepeat: Bool
}

/// The modifier state at a flags change, same decode boundary.
struct ModifierKeys {
    var cmd: Bool
    var shift: Bool
}

/// Interaction: mouse dragging and keyboard nudge/align/selection. All mutate the shared
/// `state` and broadcast a redraw. (Resolution/mode handling lives in
/// Arranger+Resolution; the context menu in Arranger+Menu.) Framework-free: events
/// arrive pre-decoded (KeyInput/ModifierKeys, gesture points, the option flag).
extension Arranger {

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

    /// Gesture began (the SwiftUI DragGesture's first change — a plain click included).
    /// `p` is in this view's (y-down) coordinates; window keying happens in the schematic
    /// host's mouseDown, before the gesture fires.
    func mouseBegan(at p: CGPoint, option: Bool) {
        mouseGestureActive = true
        // Mirror-column buttons, hit-tested against the same pure layout the draw uses.
        if let hit = mirrorColumnHit(at: p) {
            switch hit {
            case .unmirror(let id): commander?.unmirror(id)
            case .airplaySettings: commander?.openAirPlaySettings()
            }
            return
        }
        // Grabbing the main tile's menu-bar strip starts a "move main" drag.
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
        optionMirrorDrag = option && planeDisplays.count > 1
        state.draggingDisplayID = d.id   // brighten the grabbed display's screen from click
        state.beginDragLock()            // freeze unmoved displays' point positions for the drag
        dragStartMouse = p
        dragTransform = transform(plane)      // freeze so the cursor mapping is stable
        dragStartPhys = plane[d.id]?.origin ?? .zero
        dragMoved = false
        activeV = nil; activeH = nil
        emitPreview()
    }

    func mouseMoved(to p: CGPoint) {
        if draggingMenuBar != nil {
            draggingMenuBar = p
            // Would-be main follows the strip, so the Dock prediction updates live.
            let over = display(at: p)
            state.pendingMainID = over?.id ?? displays.first { $0.isMain }?.id
            state.notify()
            return
        }
        // Option-mirror drag: don't move the plane; just track the drop target.
        if optionMirrorDrag { mirrorDragPoint = p; dragMoved = true; repaintSchematic(); return }
        guard let id = draggedID, let dragged = displays.first(where: { $0.id == id }),
              let t = dragTransform ?? transform(plane) else { return }
        // 1:1 cursor tracking: view delta ÷ scale = physical delta (both y-down).
        let free = CGPoint(x: dragStartPhys.x + (p.x - dragStartMouse.x) / t.scale,
                           y: dragStartPhys.y + (p.y - dragStartMouse.y) / t.scale)
        let snap = SchematicSnapping.dockAndSnap(dragged: SchematicLayout.physSize(dragged), id: id,
                                                 free: free, scale: t.scale, snap: true, plane: plane)
        activeV = snap.activeV; activeH = snap.activeH
        guard snap.origin != plane[id]?.origin else { return }
        if !dragMoved { state.pushUndo() }   // snapshot before the drag's first move
        state.setPlaneRect(CGRect(origin: snap.origin, size: SchematicLayout.physSize(dragged)), for: id)
        dragMoved = true
        repaintSchematic()
        emitPreview()
    }

    func mouseEnded(at p: CGPoint) {
        defer { mouseGestureActive = false
                draggedID = nil; dragMoved = false; dragTransform = nil; draggingMenuBar = nil
                optionMirrorDrag = false; mirrorDragPoint = nil; state.pendingMainID = nil
                state.draggingDisplayID = nil; state.endDragLock(); state.notify() }
        // Dropped the menu-bar strip: whichever tile it's over becomes main.
        if let strip = draggingMenuBar {
            repaintSchematic()
            if let d = display(at: strip), !d.isMain { commander?.setMainDisplay(d.id) }
            return
        }
        // Option-mirror drop: if released over a *different* plane tile, mirror the
        // dragged display (slave) onto that tile (master).
        if optionMirrorDrag, let slave = draggedID {
            mirrorDragPoint = nil
            if let target = display(at: p), target.id != slave {
                commander?.setMirror(slave: slave, master: target.id)
            }
            repaintSchematic()
            return
        }
        guard draggedID != nil else { return }
        guard dragMoved else { repaintSchematic(); return } // click, no move: plane unchanged
        commitPlane()
    }

    // MARK: - Keyboard (entered via EventPlumbing's monitors, not the responder chain;
    // ArrangerWindows routes events to the key window's canvas)

    /// Returns true to consume; false lets dispatch continue (the bar's
    /// .keyboardShortcut equivalents, text fields elsewhere).
    func handleKeyDown(_ key: KeyInput) -> Bool {
        // Escape / Return / ⌘Return = Done (commit & exit).
        if key.code == 53 || key.code == 36 || key.code == 76 {
            commander?.dismissArranger(); return true
        }

        if key.cmd, let ch = key.chars, "+=-_0".contains(ch) {
            if !key.isRepeat {
                if key.shift { handleGlobalResolutionKey(ch) } else { handleResolutionKey(ch) }
            }
            return true
        }
        guard let dir = direction(key) else { return false }

        if key.cmd && key.shift {
            guard !key.isRepeat else { return true }
            guard selectedID != nil else { Chime.beep(); return true }
            stepAlignment(dir)
            alignPending = true
            emitPreview()
        } else if key.cmd {
            moveSelection(dir)
        } else {
            guard selectedID != nil else { Chime.beep(); return true }
            beginContinuousMoveIfNeeded()
            heldDirections.insert(dir)
        }
        return true
    }

    func handleKeyUp(_ key: KeyInput) -> Bool {
        guard let dir = direction(key) else { return false }
        if heldDirections.remove(dir) != nil, heldDirections.isEmpty {
            stopMoveTimer()
            commitPlane()
        }
        return true
    }

    /// Observes modifier changes (never consumes them).
    func handleFlagsChanged(_ mods: ModifierKeys) {
        shiftHeld = mods.shift   // the nudge timer reads this for its fast rate
        // Ghost the ⌘⇧ alignment destinations on every display while ⌘⇧ is held.
        let ghosts = mods.cmd && mods.shift && selectedID != nil && !zoomPending
        if ghosts != showAlignGhosts { showAlignGhosts = ghosts; emitPreview() }
        if alignPending, !(mods.cmd && mods.shift) {
            alignPending = false
            emitPreview()
            commitPlane()
        }
        if zoomPending, !mods.cmd {
            commitPendingResolution()
        }
    }

    private func direction(_ key: KeyInput) -> MoveDirection? {
        switch key.code {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: break
        }
        switch key.chars?.lowercased() {
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
        lastTick = ProcessInfo.processInfo.systemUptime
        moveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.moveTick()
        }
    }

    func stopMoveTimer() { moveTimer?.invalidate(); moveTimer = nil }

    private func moveTick() {
        guard let id = selectedID, !heldDirections.isEmpty,
              let sel = displays.first(where: { $0.id == id }) else { stopMoveTimer(); return }
        let now = ProcessInfo.processInfo.systemUptime, dt = CGFloat(now - lastTick); lastTick = now
        let rate: CGFloat = shiftHeld ? 6.0 : 1.5 // inches / sec (shift fed by flagsChanged)
        var dx: CGFloat = 0, dy: CGFloat = 0
        if heldDirections.contains(.left) { dx -= 1 }
        if heldDirections.contains(.right) { dx += 1 }
        if heldDirections.contains(.up) { dy -= 1 }   // y grows downward
        if heldDirections.contains(.down) { dy += 1 }
        nudgeAccum.x += dx * rate * dt
        nudgeAccum.y += dy * rate * dt
        // Dock + magnet; the magnet sets activeV/H so the snapping triangles show.
        let snap = SchematicSnapping.dockAndSnap(dragged: SchematicLayout.physSize(sel), id: id,
                                                 free: nudgeAccum, scale: drawTransform(plane)?.scale ?? 1,
                                                 snap: true, plane: plane)
        activeV = snap.activeV; activeH = snap.activeH
        state.setPlaneRect(CGRect(origin: snap.origin, size: SchematicLayout.physSize(sel)), for: id)
        repaintSchematic()
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

    /// Apply one ⌘⇧ alignment step to the selected tile.
    private func stepAlignment(_ dir: MoveDirection) {
        guard let id = selectedID else { return }
        state.pushUndo()   // snapshot before each alignment step
        guard SchematicSnapping.currentJoin(id, plane: plane) != nil else {
            // Not docked yet: dock to the nearest neighbor (a join for the next press).
            if let sel = displays.first(where: { $0.id == id }) {
                let snap = SchematicSnapping.dockAndSnap(dragged: SchematicLayout.physSize(sel), id: id,
                                                         free: plane[id]?.origin ?? .zero,
                                                         scale: drawTransform(plane)?.scale ?? 1, snap: true, plane: plane)
                activeV = snap.activeV; activeH = snap.activeH
                state.setPlaneRect(CGRect(origin: snap.origin, size: SchematicLayout.physSize(sel)), for: id)
            }
            emitPreview()
            return
        }
        // Same source the ghost preview reads, so what was previewed is what applies.
        guard let o = SchematicSnapping.plannedMoves(id, plane: plane, activeV: activeV, activeH: activeH)[dir] else { return }
        state.setPlaneRect(CGRect(origin: o, size: plane[id]!.size), for: id)
        let m = SchematicSnapping.markerForJoin(id, plane: plane)
        activeV = m.v; activeH = m.h
        emitPreview()
    }

    /// The valid ⌘⇧ arrow destinations — the same `plannedMoves` map `stepAlignment`
    /// applies from, so preview and apply agree.
    func alignGhosts() -> [(dir: MoveDirection, rect: CGRect)] {
        guard let id = selectedID, let size = plane[id]?.size else { return [] }
        return SchematicSnapping.plannedMoves(id, plane: plane, activeV: activeV, activeH: activeH)
            .map { (dir, origin) in (dir, CGRect(origin: origin, size: size)) }
    }
}
