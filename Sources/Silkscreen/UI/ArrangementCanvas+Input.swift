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
        // The tile tracks the cursor 1:1: view delta ÷ scale = physical delta.
        let free = CGPoint(x: dragStartPhys.x + (p.x - dragStartMouse.x) / t.scale,
                           y: dragStartPhys.y + (p.y - dragStartMouse.y) / t.scale)
        let resolved = dockAndSnap(dragged, free: free, scale: t.scale, snap: true)
        guard resolved != plane[id]?.origin else { return }
        if !dragMoved { state.pushUndo() }   // snapshot before the drag's first move
        plane[id] = CGRect(origin: resolved, size: SchematicLayout.physSize(dragged))
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

        // 2) Magnet the slide to a physical anchor of the docked-to neighbor (within a
        //    few view px). The primary dock fixes the perpendicular axis; here we snap
        //    the *along* axis.
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

        // 3) Corner detent: with the tile docked to the primary neighbor, look for a
        //    *second* neighbor it can also seat flush against along the free axis, and
        //    prefer that (so dragging into an L-corner snaps into the corner). Only a
        //    second neighbor that would actually overlap the tile's docked span counts.
        best = cornerSnap(best, size: dP, along: verticalSeam, primary: o.id, threshold: threshold, others: others)
        return best
    }

    /// If, once docked to the primary neighbor, the tile can also sit flush against a
    /// second neighbor along the free axis (within `threshold`), snap it there so it
    /// seats into the corner — setting the perpendicular active marker too. `along`
    /// vertical ⇒ the free axis is y (snap top/bottom to a second neighbor's edge).
    private func cornerSnap(_ pos: CGPoint, size dP: CGSize, along verticalSeam: Bool,
                            primary: CGDirectDisplayID, threshold: CGFloat,
                            others: [CGDirectDisplayID: CGRect]) -> CGPoint {
        var best = pos, bestD = threshold, snapped = false
        var snappedID: CGDirectDisplayID?, snapEdgeIsMin = false
        // A candidate along-position is only valid if seating there doesn't overlap any
        // other display (it can slide into a third tile).
        func clear(_ origin: CGPoint) -> Bool {
            let rect = CGRect(origin: origin, size: dP).insetBy(dx: 0.1, dy: 0.1)
            return !others.contains { $0.value.intersects(rect) }
        }
        for (oid, oR) in others where oid != primary {
            if verticalSeam {
                // Free axis is y; a second neighbor whose x abuts the tile can seat its
                // top or bottom flush. Require x-overlap so it's genuinely a corner.
                guard min(pos.x + dP.width, oR.maxX) - max(pos.x, oR.minX) > 0.05 else { continue }
                for (edge, isMin) in [(oR.minY - dP.height, false), (oR.maxY, true)] {
                    let d = abs(edge - pos.y)
                    if d < bestD, clear(CGPoint(x: pos.x, y: edge)) {
                        bestD = d; best.y = edge; snapped = true; snappedID = oid; snapEdgeIsMin = isMin
                    }
                }
            } else {
                guard min(pos.y + dP.height, oR.maxY) - max(pos.y, oR.minY) > 0.05 else { continue }
                for (edge, isMin) in [(oR.minX - dP.width, false), (oR.maxX, true)] {
                    let d = abs(edge - pos.x)
                    if d < bestD, clear(CGPoint(x: edge, y: pos.y)) {
                        bestD = d; best.x = edge; snapped = true; snappedID = oid; snapEdgeIsMin = isMin
                    }
                }
            }
        }
        // Reflect the second seam in the perpendicular marker (self meets the second
        // neighbor edge-to-edge: our leading edge on its trailing edge, or vice versa).
        if snapped, let sid = snappedID {
            // snapEdgeIsMin ⇒ tile seated on the neighbor's max edge (tile below/right):
            // tile's leading edge meets the neighbor's trailing edge, and vice versa.
            if verticalSeam {
                activeV = snapEdgeIsMin ? (.top, .bottom, sid) : (.bottom, .top, sid)
            } else {
                activeH = snapEdgeIsMin ? (.left, .right, sid) : (.right, .left, sid)
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
        plane[id] = CGRect(origin: dockAndSnap(sel, free: nudgeAccum, scale: transform(plane)?.scale ?? 1, snap: true),
                           size: SchematicLayout.physSize(sel))
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
        guard currentJoin(id) != nil else {
            // Not docked yet: dock to the nearest neighbor (a join for the next press).
            if let sel = displays.first(where: { $0.id == id }) {
                plane[id] = CGRect(origin: dockAndSnap(sel, free: plane[id]?.origin ?? .zero,
                                                       scale: transform(plane)?.scale ?? 1, snap: true),
                                   size: SchematicLayout.physSize(sel))
            }
            emitPreview()
            return
        }
        guard let o = plannedOrigin(id, dir) else { return }
        plane[id] = CGRect(origin: o, size: plane[id]!.size)
        setActive(id)
        emitPreview()
    }

    /// Where the selected tile would go for `dir`, without applying it. Pure, so the
    /// ⌘⇧ ghost preview can show each valid arrow's destination. nil ⇒ no-op.
    ///
    /// The arrow along the current seam cycles the seven anchors (wrapping around the
    /// corner onto the perpendicular edge at an end); the arrow across the seam flips
    /// the tile to the neighbor's edge in that direction. So the presses walk the tile
    /// around the neighbor like a clock.
    private func plannedOrigin(_ id: CGDirectDisplayID, _ dir: MoveDirection) -> CGPoint? {
        guard let join = currentJoin(id) else { return nil }
        if join.vertical {   // seam is vertical → along = up/down, across = left/right
            return dir.isVertical ? cycleOrigin(id, other: join.otherID, vertical: true, increasing: dir == .down)
                                  : flipOrigin(id, around: join.otherID, dir: dir)
        } else {             // seam is horizontal → along = left/right, across = up/down
            return !dir.isVertical ? cycleOrigin(id, other: join.otherID, vertical: false, increasing: dir == .right)
                                   : flipOrigin(id, around: join.otherID, dir: dir)
        }
    }

    /// Origin one anchor along the seam; at an extreme, wraps around the corner.
    private func cycleOrigin(_ id: CGDirectDisplayID, other oid: CGDirectDisplayID, vertical: Bool, increasing: Bool) -> CGPoint? {
        guard let r = plane[id], let oR = plane[oid] else { return nil }
        let step = increasing ? 1 : -1
        if vertical {
            let snaps = SchematicLayout.physSnapsV(childHeight: r.height, parent: oR)
            let cur = activeV?.otherID == oid
                ? (snaps.firstIndex { $0.selfAnchor == activeV!.selfA && $0.otherAnchor == activeV!.otherA } ?? nearestIndex(snaps.map(\.along), r.minY))
                : nearestIndex(snaps.map(\.along), r.minY)
            let next = cur + step
            if next < 0 || next >= snaps.count { return wrapOrigin(id, around: oid, fromVerticalSeam: true, increasing: increasing) }
            return CGPoint(x: r.minX, y: snaps[next].along)
        } else {
            let snaps = SchematicLayout.physSnapsH(childWidth: r.width, parent: oR)
            let cur = activeH?.otherID == oid
                ? (snaps.firstIndex { $0.selfAnchor == activeH!.selfA && $0.otherAnchor == activeH!.otherA } ?? nearestIndex(snaps.map(\.along), r.minX))
                : nearestIndex(snaps.map(\.along), r.minX)
            let next = cur + step
            if next < 0 || next >= snaps.count { return wrapOrigin(id, around: oid, fromVerticalSeam: false, increasing: increasing) }
            return CGPoint(x: snaps[next].along, y: r.minY)
        }
    }

    private func nearestIndex(_ values: [CGFloat], _ current: CGFloat) -> Int {
        var bestI = 0, bestD = CGFloat.greatestFiniteMagnitude
        for (i, v) in values.enumerated() where abs(v - current) < bestD { bestD = abs(v - current); bestI = i }
        return bestI
    }

    /// Origin on the neighbor's edge in the pressed direction, same along-anchor —
    /// nil if already on that side (no toggle-back). Up→above, Down→below, etc.
    private func flipOrigin(_ id: CGDirectDisplayID, around oid: CGDirectDisplayID, dir: MoveDirection) -> CGPoint? {
        guard let r = plane[id], let O = plane[oid] else { return nil }
        switch dir {
        case .left  where r.minX > O.minX: return CGPoint(x: O.minX - r.width, y: r.minY)
        case .right where r.maxX < O.maxX: return CGPoint(x: O.maxX, y: r.minY)
        case .up    where r.minY > O.minY: return CGPoint(x: r.minX, y: O.minY - r.height)
        case .down  where r.maxY < O.maxY: return CGPoint(x: r.minX, y: O.maxY)
        default: return nil   // already on that side
        }
    }

    /// Origin after wrapping onto the perpendicular edge (turning the corner), snapped
    /// to the corner anchor it wrapped past.
    private func wrapOrigin(_ id: CGDirectDisplayID, around oid: CGDirectDisplayID, fromVerticalSeam: Bool, increasing: Bool) -> CGPoint? {
        guard let r = plane[id], let O = plane[oid] else { return nil }
        if fromVerticalSeam {
            let onRight = abs(r.minX - O.maxX) < 0.1
            let y = increasing ? O.maxY : O.minY - r.height        // below / above O
            let snaps = SchematicLayout.physSnapsH(childWidth: r.width, parent: O)
            return CGPoint(x: (onRight ? snaps.last! : snaps.first!).along, y: y)
        } else {
            let below = abs(r.minY - O.maxY) < 0.1
            let x = increasing ? O.maxX : O.minX - r.width         // right / left of O
            let snaps = SchematicLayout.physSnapsV(childHeight: r.height, parent: O)
            return CGPoint(x: x, y: (below ? snaps.last! : snaps.first!).along)
        }
    }

    /// Recompute the active-anchor marker for the tile's current join.
    private func setActive(_ id: CGDirectDisplayID) {
        guard let r = plane[id], let join = currentJoin(id), let oR = plane[join.otherID] else { return }
        if join.vertical {
            let snaps = SchematicLayout.physSnapsV(childHeight: r.height, parent: oR)
            let i = nearestIndex(snaps.map(\.along), r.minY)
            activeV = (snaps[i].selfAnchor, snaps[i].otherAnchor, join.otherID); activeH = nil
        } else {
            let snaps = SchematicLayout.physSnapsH(childWidth: r.width, parent: oR)
            let i = nearestIndex(snaps.map(\.along), r.minX)
            activeH = (snaps[i].selfAnchor, snaps[i].otherAnchor, join.otherID); activeV = nil
        }
    }

    /// The valid ⌘⇧ arrow destinations (grey-ghosted while ⌘⇧ is held) for the
    /// selected tile: each arrow's move direction and the physical rect it lands on
    /// (skipping no-ops).
    func alignGhosts() -> [(dir: MoveDirection, rect: CGRect)] {
        guard let id = selectedID, let size = plane[id]?.size, currentJoin(id) != nil else { return [] }
        return [MoveDirection.up, .down, .left, .right]
            .compactMap { d in plannedOrigin(id, d).map { (d, CGRect(origin: $0, size: size)) } }
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
