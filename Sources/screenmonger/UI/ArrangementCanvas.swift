import AppKit

/// Interactive visualization + editor of the display arrangement.
///
/// The schematic is drawn at true physical sizes. While the user manipulates it
/// (drag / keyboard), a **physical plane** — `plane`, a rect per display in inches
/// — is the source of truth: dragging moves a rect on the plane 1:1 with the
/// cursor, and snapping/alignment are physical. Only when the manipulation ends
/// (mouse up / modifier released) do we convert the plane back to a macOS *point*
/// arrangement (via `SchematicLayout.toPoints`) and commit. The point↔
/// physical seam map is thus applied at exactly two boundaries — interpret the
/// committed layout onto the plane, convert the plane back — never per frame.
///
/// Keys (selected display): ⌘+arrows/WASD change selection; arrows/WASD nudge;
/// ⌘⇧+arrows/WASD step alignment; ⌘ +/−/0 change resolution.
final class ArrangementCanvas: NSView {

    /// Shared editing state — one instance across every per-screen canvas.
    let state: ArrangementState
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let buttonBar = NSVisualEffectView()

    init(state: ArrangementState, frame: NSRect) {
        self.state = state
        super.init(frame: frame)
        setupButtonBar()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Idiomatic bottom button bar (Reset · Undo · Done) grouped in a rounded box,
    /// on every screen, sitting above the Dock.
    private func setupButtonBar() {
        resetButton.keyEquivalent = "\u{8}"; resetButton.keyEquivalentModifierMask = .command  // ⌘Delete
        resetButton.target = self; resetButton.action = #selector(resetTapped)
        undoButton.keyEquivalent = "z"; undoButton.keyEquivalentModifierMask = .command
        undoButton.target = self; undoButton.action = #selector(undoTapped)
        doneButton.target = self; doneButton.action = #selector(doneTapped)  // Enter/⌘Enter via keyDown
        for b in [resetButton, undoButton, doneButton] { b.bezelStyle = .rounded }

        let stack = NSStackView(views: [resetButton, undoButton, doneButton])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        buttonBar.material = .hudWindow
        buttonBar.blendingMode = .withinWindow
        buttonBar.state = .active
        buttonBar.wantsLayer = true
        buttonBar.layer?.cornerRadius = 12
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        buttonBar.addSubview(stack)
        addSubview(buttonBar)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: buttonBar.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: buttonBar.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: buttonBar.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: buttonBar.trailingAnchor, constant: -16),
            buttonBar.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        buttonBarBottom = buttonBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -80)
        buttonBarBottom?.isActive = true
    }

    private var buttonBarBottom: NSLayoutConstraint?

    /// Keep the button bar above the Dock (which intrudes on visibleFrame, not the safe
    /// area, for a full-screen borderless window) and clear of a bottom-edge alignment
    /// arrow (which lives ~40–65px up from the screen bottom).
    override func layout() {
        super.layout()
        if let screen = window?.screen {
            // Height the Dock lifts the visible area off the screen's bottom edge.
            let dockInset = max(0, screen.visibleFrame.minY - screen.frame.minY)
            buttonBarBottom?.constant = -80 - dockInset
        }
    }

    @objc private func resetTapped() { state.onReset?() }
    @objc private func undoTapped() { state.undo() }
    @objc private func doneTapped() { onDismiss?() }

    /// Reflect undo availability (a plane edit or a pending revert) on the Undo button.
    private func syncButtons() {
        undoButton.isEnabled = state.canUndo
    }

    // Forwarding accessors so this view's methods read/write the shared state.
    private var displays: [DisplaySnapshot] { get { state.displays } set { state.displays = newValue } }
    private var colorFor: [CGDirectDisplayID: NSColor] { state.colorFor }
    private var selectedID: CGDirectDisplayID? { get { state.selectedID } set { state.selectedID = newValue } }
    private var plane: [CGDirectDisplayID: CGRect] { get { state.plane } set { state.plane = newValue } }
    private var pendingSize: [CGDirectDisplayID: CGSize] { get { state.pendingSize } set { state.pendingSize = newValue } }
    private var pendingMode: (id: CGDirectDisplayID, mode: CGDisplayMode)? { get { state.pendingMode } set { state.pendingMode = newValue } }
    private var activeV: (selfA: VAnchor, otherA: VAnchor, otherID: CGDirectDisplayID)? { get { state.activeV } set { state.activeV = newValue } }
    private var activeH: (selfA: HAnchor, otherA: HAnchor, otherID: CGDirectDisplayID)? { get { state.activeH } set { state.activeH = newValue } }
    var extendedBuiltinModes: Bool { get { state.extendedBuiltinModes } set { state.extendedBuiltinModes = newValue } }

    // Convenience forwards to the shared callbacks.
    private var onCommit: (([CGDirectDisplayID: CGPoint]) -> Void)? { state.onCommit }
    private var onSetMain: ((CGDirectDisplayID) -> Void)? { state.onSetMain }
    private var onSetResolution: ((CGDirectDisplayID, CGDisplayMode, [CGDirectDisplayID: CGPoint]) -> Void)? { state.onSetResolution }
    private var onCalibrate: ((CGDirectDisplayID) -> Void)? { state.onCalibrate }
    private var onCalibrateVisual: ((CGDirectDisplayID) -> Void)? { state.onCalibrateVisual }
    private var onResetCalibration: ((CGDirectDisplayID) -> Void)? { state.onResetCalibration }
    private var onDismiss: (() -> Void)? { state.onDismiss }

    // Mouse drag state (local to the canvas handling the gesture).
    private var draggedID: CGDirectDisplayID?
    private var dragStartMouse: CGPoint = .zero
    private var dragStartPhys: CGPoint = .zero    // dragged tile's physical origin at grab
    private var dragTransform: Transform?         // frozen during a drag (stable cursor mapping)
    private var dragMoved = false

    // Dragging the main display's menu-bar strip to move main to another tile.
    private var draggingMenuBar: CGPoint?         // current cursor point while dragging

    // Keyboard continuous-move (nudge) state.
    private var heldDirections: Set<MoveDirection> = []
    private var moveTimer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var nudgeAccum: CGPoint = .zero        // physical accumulator, like a cursor

    // One alignment step per ⌘⇧ press; commits when ⌘⇧ is released.
    private var alignPending = false

    // Resolution preview flag (commits the pending mode when ⌘ is released).
    private var zoomPending = false

    /// The display this canvas's window sits on — its tile is centered in the view.
    /// nil ⇒ center the main display (single-window fallback).
    var centerID: CGDirectDisplayID?

    private let outerPadding: CGFloat = 32
    private let tileCornerRadius: CGFloat = 8

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // Deliver clicks even when this window isn't key, so any screen's arranger reacts
    // immediately (no activate-first click).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Called by the state after a mutation so this view repaints.
    func refresh() { syncButtons(); needsDisplay = true }

    private func pointSize(_ d: DisplaySnapshot) -> CGSize { state.pointSize(d) }
    private func sizedDisplays() -> [DisplaySnapshot] { state.sizedDisplays() }
    private func currentRects() -> [CGDirectDisplayID: CGRect] { plane }
    func currentBars() -> [SeamBar] { state.currentBars() }

    /// Commit the plane, then broadcast so every canvas redraws.
    private func commitPlane() { state.commit() }

    /// Push the plane's bars to the on-glass overlay so it tracks the manipulation.
    /// Broadcast a plane change so every per-screen canvas redraws.
    private func emitPreview() { state.notify() }

    // MARK: - View transform (fit the physical plane into the window)

    private struct Transform {
        let scale: CGFloat            // view px per inch
        let offset: CGPoint
        let unionOrigin: CGPoint
        func viewRect(_ r: CGRect) -> CGRect {
            CGRect(x: offset.x + (r.minX - unionOrigin.x) * scale,
                   y: offset.y + (r.minY - unionOrigin.y) * scale,
                   width: r.width * scale, height: r.height * scale)
        }
        func viewPoint(_ g: CGPoint) -> CGPoint {
            CGPoint(x: offset.x + (g.x - unionOrigin.x) * scale, y: offset.y + (g.y - unionOrigin.y) * scale)
        }
    }

    private func transform(_ rects: [CGDirectDisplayID: CGRect]) -> Transform? {
        let values = Array(rects.values)
        guard let first = values.first else { return nil }
        let union = values.dropFirst().reduce(first) { $0.union($1) }
        guard union.width > 0, union.height > 0 else { return nil }

        // Center this screen's own tile (or the main, as a fallback) at the view midpoint.
        let focusRect = (centerID.flatMap { rects[$0] })
            ?? displays.first(where: { $0.isMain }).flatMap { rects[$0.id] } ?? union
        let focus = CGPoint(x: focusRect.midX, y: focusRect.midY)

        let availW = bounds.width - outerPadding * 2, availH = bounds.height - outerPadding * 2

        // Target zoom: three of the physically-largest display fit across the view,
        // matching axes — 3 widths across the view width, 3 heights down its height —
        // so a landscape screen isn't over-shrunk by its (smaller) height.
        let largestW = rects.values.map(\.width).max() ?? union.width
        let largestH = rects.values.map(\.height).max() ?? union.height
        let targetScale = min(availW / (3 * max(largestW, 0.0001)),
                              availH / (3 * max(largestH, 0.0001)))

        // But never let the layout overflow: cap so the union fits with padding.
        // The focus tile is centered, so each axis is limited by the union's farther side.
        let reachX = max(focus.x - union.minX, union.maxX - focus.x)
        let reachY = max(focus.y - union.minY, union.maxY - focus.y)
        let fitScale = min(availW / 2 / max(reachX, 0.0001), availH / 2 / max(reachY, 0.0001))
        let scale = min(targetScale, fitScale)

        // Offset so the focus tile lands at the view midpoint.
        let offset = CGPoint(x: bounds.midX - (focus.x - union.minX) * scale,
                             y: bounds.midY - (focus.y - union.minY) * scale)
        return Transform(scale: scale, offset: offset, unionOrigin: union.origin)
    }

    // MARK: - Mouse / dragging

    private func display(at p: CGPoint) -> DisplaySnapshot? {
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
        // Clicking any screen's arranger focuses it, so keyboard (zoom/align) follows
        // the click without needing to activate the window first.
        window?.makeKeyAndOrderFront(nil)
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

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Each per-screen window owns its own dim backdrop.
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()

        let rects = currentRects()
        guard let t = dragTransform ?? transform(rects) else {
            drawCenteredMessage("No displays detected")
            return
        }
        let bars = currentBars()
        for d in displays where rects[d.id] != nil { drawTile(for: d, in: t.viewRect(rects[d.id]!)) }
        drawReferenceBars(bars, t: t)
        let markers = activeMarkers(rects)
        for d in displays where rects[d.id] != nil { drawAnchors(for: d, in: t.viewRect(rects[d.id]!), active: markers[d.id]) }
        drawEdgeBars(bars)      // full-screen reference bars hugging this screen's real edges
        drawScreenMarkers(activeMarkers(rects))   // alignment notches/arrows at this screen's real edges
        drawFooter("Drag to rearrange · ⌘/arrows select · arrows nudge · ⌘⇧ align · ⌘ ± 0 resolution")
        if let p = draggingMenuBar {
            // The strip follows the cursor; highlight the tile it would land on.
            if let over = display(at: p), !over.isMain, let r = rects[over.id] {
                let vr = t.viewRect(r).insetBy(dx: 1.5, dy: 1.5)
                NSColor.white.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: vr, xRadius: tileCornerRadius, yRadius: tileCornerRadius).fill()
            }
            drawMenuBar(in: NSRect(x: p.x - 40, y: p.y - 8, width: 80, height: 16))
        }
    }

    /// Reference bars at each seam, from the shared `SchematicLayout`: the reference
    /// window shown on each side in the facing color, at its own physical size (which
    /// differs by density — the size jump a window makes crossing the seam).
    private func drawReferenceBars(_ bars: [SeamBar], t: Transform) {
        let thickness: CGFloat = 5, gap: CGFloat = 5   // inset each bar off the seam line
        let trim: CGFloat = 8                          // shorten so ends clear the tile's rounded corners
        for bar in bars {
            let lenA = max(2, bar.physLenInchesA * t.scale - trim)
            let lenB = max(2, bar.physLenInchesB * t.scale - trim)
            if bar.isVertical {
                let cA = t.viewPoint(CGPoint(x: bar.physLine, y: bar.physAlongA))
                let cB = t.viewPoint(CGPoint(x: bar.physLine, y: bar.physAlongB))
                drawBar(NSRect(x: cA.x - thickness - gap, y: cA.y - lenA / 2, width: thickness, height: lenA))
                drawBar(NSRect(x: cB.x + gap, y: cB.y - lenB / 2, width: thickness, height: lenB))
            } else {
                let cA = t.viewPoint(CGPoint(x: bar.physAlongA, y: bar.physLine))
                let cB = t.viewPoint(CGPoint(x: bar.physAlongB, y: bar.physLine))
                drawBar(NSRect(x: cA.x - lenA / 2, y: cA.y - thickness - gap, width: lenA, height: thickness))
                drawBar(NSRect(x: cB.x - lenB / 2, y: cB.y + gap, width: lenB, height: thickness))
            }
        }
    }

    /// Mini-map reference bars are drawn fully white (the on-glass edge bars keep
    /// each display's color).
    private func drawBar(_ rect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    }

    /// Full-screen reference bars hugging *this* screen's real edges (in its own
    /// point coordinates), in the facing display's color — the on-glass depiction of
    /// how big a window is as it crosses the seam. Drawn only on the window that sits
    /// on the participating screen.
    private func drawEdgeBars(_ bars: [SeamBar]) {
        guard let me = centerID else { return }
        let thickness: CGFloat = 9, endMargin: CGFloat = 6
        // On a notched display, keep top-edge bars below the menu-bar/notch area.
        let notch = window?.screen?.safeAreaInsets.top ?? 0
        for bar in bars where bar.aID == me || bar.bID == me {
            let weAreA = (bar.aID == me)
            let facing = colorFor[weAreA ? bar.bID : bar.aID] ?? .systemGray
            let along = weAreA ? bar.localAlongA : bar.localAlongB
            let len = max(0, bar.windowPoints - 2 * endMargin)   // small margin at each end
            let rect: NSRect
            // `inward` is the side facing the screen center (rounded); the opposite,
            // outward side sits flat against the screen edge.
            let inward: RectEdge
            if bar.isVertical {
                let x = weAreA ? bounds.width - thickness : 0    // a = left display
                rect = NSRect(x: x, y: along - len / 2, width: thickness, height: len)
                inward = weAreA ? .minX : .maxX                  // a hugs the right edge → rounds left
            } else {
                let y = weAreA ? bounds.height - thickness : notch
                rect = NSRect(x: along - len / 2, y: y, width: len, height: thickness)
                inward = weAreA ? .minY : .maxY
            }
            facing.setFill()
            dPath(rect, roundedOn: inward).fill()
        }
    }

    private enum RectEdge { case minX, maxX, minY, maxY }

    /// A rounded rect with only the two corners on the `inward` edge rounded (the
    /// outward edge and its corners stay square). `appendArc(from:to:radius:)` rounds
    /// each traversed corner; feeding radius 0 at the outward corners keeps them flat.
    private func dPath(_ r: NSRect, roundedOn inward: RectEdge) -> NSBezierPath {
        let cr = min(r.width, r.height) * 0.45   // corner radius on the inward side
        // Corners in order (bl, br, tr, tl) with the radius to use at each.
        let bl = CGPoint(x: r.minX, y: r.minY), br = CGPoint(x: r.maxX, y: r.minY)
        let tr = CGPoint(x: r.maxX, y: r.maxY), tl = CGPoint(x: r.minX, y: r.maxY)
        func rad(_ c: RectEdge...) -> CGFloat { c.contains(inward) ? cr : 0 }
        // Radius per corner: a corner is rounded iff it lies on the inward edge.
        let rBL = rad(.minX, .minY), rBR = rad(.maxX, .minY)
        let rTR = rad(.maxX, .maxY), rTL = rad(.minX, .maxY)

        let p = NSBezierPath()
        p.move(to: CGPoint(x: (bl.x + br.x) / 2, y: bl.y))     // start mid-bottom (away from a corner)
        p.appendArc(from: br, to: tr, radius: rBR)
        p.appendArc(from: tr, to: tl, radius: rTR)
        p.appendArc(from: tl, to: bl, radius: rTL)
        p.appendArc(from: bl, to: br, radius: rBL)
        p.close()
        return p
    }

    private func drawTile(for display: DisplaySnapshot, in rect: NSRect) {
        let color = colorFor[display.id] ?? .systemGray
        let selected = display.id == selectedID
        let inset = rect.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: tileCornerRadius, yRadius: tileCornerRadius)
        color.withAlphaComponent(selected ? 0.95 : 0.8).setFill(); path.fill()
        // The selected tile is outlined white so it's clear which display a zoom /
        // resolution change will affect.
        (selected ? NSColor.white : color).setStroke()
        path.lineWidth = selected ? 3 : 1.5; path.stroke()
        drawBoxing(for: display, in: inset, color: color)
        drawLabel(for: display, in: inset)
        // The main display carries a menu-bar strip (drag it to another tile to move main).
        if display.isMain, draggingMenuBar == nil { drawMenuBar(in: menuBarRect(inTile: inset)) }
    }

    /// If the current (or previewed) mode's aspect ratio doesn't match the panel's
    /// physical shape, the image is letter-/pillar-boxed. Draw the actual image area as
    /// an inset rectangle and hatch the black-bar regions so it's obvious.
    private func drawBoxing(for display: DisplaySnapshot, in tile: NSRect, color: NSColor) {
        // Image aspect from the current or pending pixel resolution.
        let pending = pendingMode?.id == display.id ? pendingMode?.mode : nil
        let imgW = Double(pending?.pixelWidth ?? Int(display.pixelSize.width))
        let imgH = Double(pending?.pixelHeight ?? Int(display.pixelSize.height))
        // Compare against the panel's *native pixel* aspect (not physical mm, which is
        // imprecise and gives false positives on a full-panel mode).
        guard imgW > 0, imgH > 0, let panAspect = nativeAspect(display.id) else { return }
        let imgAspect = imgW / imgH
        guard abs(imgAspect - panAspect) / panAspect > 0.02 else { return }   // fills the panel

        // The image rect: the largest tile-centered rect with the image's aspect.
        var img = tile.insetBy(dx: 2, dy: 2)
        if imgAspect > panAspect {                 // wider than panel → letterbox (bars top/bottom)
            let h = img.width / CGFloat(imgAspect)
            img = NSRect(x: img.minX, y: img.midY - h / 2, width: img.width, height: h)
        } else {                                   // narrower → pillarbox (bars left/right)
            let w = img.height * CGFloat(imgAspect)
            img = NSRect(x: img.midX - w / 2, y: img.minY, width: w, height: img.height)
        }
        // Outline the image area; hatch the boxed (black-bar) regions with diagonal lines.
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let outline = NSBezierPath(rect: img); outline.lineWidth = 1; outline.stroke()
        hatch(tile.insetBy(dx: 2, dy: 2), excluding: img, color: NSColor.black.withAlphaComponent(0.3))
    }

    /// Cached native pixel aspect per display (querying all modes is a CG call, too
    /// heavy to repeat every draw). Native aspect is fixed per physical panel, so a
    /// stale entry for a disconnected id is harmless.
    private var nativeAspectCache: [CGDirectDisplayID: Double?] = [:]
    private func nativeAspect(_ id: CGDirectDisplayID) -> Double? {
        if let cached = nativeAspectCache[id] { return cached }
        let a = ModeCatalog.nativeAspect(for: id)
        nativeAspectCache[id] = a
        return a
    }

    /// Fill the region of `rect` outside `hole` with faint diagonal hatch lines.
    private func hatch(_ rect: NSRect, excluding hole: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(rect: rect)
        clip.append(NSBezierPath(rect: hole).reversed)   // even-odd hole
        clip.addClip()
        color.setStroke()
        let path = NSBezierPath(); path.lineWidth = 1
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY)); path.line(to: CGPoint(x: x + rect.height, y: rect.maxY))
            x += 6
        }
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The menu-bar strip across the top of a tile (flipped view: min-y is the top).
    /// Its full rect stays the drag target even where a reference bar draws over it.
    private func menuBarRect(inTile tile: NSRect) -> NSRect {
        return NSRect(x: tile.minX, y: tile.minY, width: tile.width, height: min(18, tile.height * 0.2))
    }

    private func drawMenuBar(in rect: NSRect) {
        let clip = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        NSColor.white.withAlphaComponent(0.6).setFill(); clip.fill()
    }

    private func drawLabel(for display: DisplaySnapshot, in rect: NSRect) {
        let sz = pointSize(display)
        let pending = pendingMode?.id == display.id ? pendingMode?.mode : nil
        let pixelW = pending?.pixelWidth ?? Int(display.pixelSize.width)

        // Effective PPI (points per physical inch) — what governs apparent window/text
        // size. Live via `pointSize`, so it tracks a zoom preview.
        let effPPI = display.diagonalInches > 0 && sz.width > 0
            ? Double(sz.width) / (Double(display.physicalSizeMM.width) / 25.4) : nil

        // Scale the label so text on the tile is proportional to how big it appears on
        // that screen: higher PPI (denser) → physically smaller → smaller tile text.
        // Normalized around a typical ~110 ppi (with an overall +25% bump). Generous
        // caps (up to ~4×) — the per-line width check below drops anything that still
        // wouldn't fit, so we don't need a tight constant clamp.
        let fontScale = CGFloat(max(0.5, min(4.0, 110.0 / (effPPI ?? 110)))) * 1.25
        func f(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
            let base = bold ? NSFont.boldSystemFont(ofSize: size * fontScale) : .systemFont(ofSize: size * fontScale)
            return italic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
        }

        var lines: [(String, NSFont, NSColor)] = []
        lines.append((display.name, f(16, bold: true), .labelColor))

        // Resolution "W×H" (points) with HiDPI tagged on; italic while a zoom mode is
        // uncommitted.
        let hidpi = pixelW > Int(sz.width) ? " HiDPI" : ""
        lines.append(("\(Int(sz.width))×\(Int(sz.height))" + hidpi, f(13, italic: pending != nil), .labelColor))

        // Diagonal inches then effective PPI.
        let diag = display.diagonalInches > 0 ? String(format: "%.0f″ · ", display.diagonalInches) : ""
        if let effPPI {
            lines.append((diag + String(format: "%.0f ppi", effPPI), f(13), .secondaryLabelColor))
        } else {
            lines.append((diag + "calibrate?", f(13), .secondaryLabelColor))
        }

        // Center the block vertically and each line horizontally in the tile.
        let attrsFor: (NSFont) -> [NSAttributedString.Key: Any] = { [.font: $0] }
        let sizes = lines.map { ($0.0 as NSString).size(withAttributes: attrsFor($0.1)) }
        let gap: CGFloat = 3
        let total = sizes.reduce(0) { $0 + $1.height } + gap * CGFloat(lines.count - 1)
        var y = rect.midY - total / 2
        for (i, (text, font, color)) in lines.enumerated() {
            let s = sizes[i]
            guard s.width <= rect.width - 8 else { y += s.height + gap; continue }
            (text as NSString).draw(at: CGPoint(x: rect.midX - s.width / 2, y: y),
                                    withAttributes: [.font: font, .foregroundColor: color])
            y += s.height + gap
        }
    }

    /// The eight perimeter anchor positions (corners + edge midpoints).
    private enum AnchorPos: CaseIterable {
        case topLeft, topMid, topRight, leftMid, rightMid, bottomLeft, bottomMid, bottomRight
        func point(in r: NSRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: r.minX, y: r.minY)
            case .topMid: return CGPoint(x: r.midX, y: r.minY)
            case .topRight: return CGPoint(x: r.maxX, y: r.minY)
            case .leftMid: return CGPoint(x: r.minX, y: r.midY)
            case .rightMid: return CGPoint(x: r.maxX, y: r.midY)
            case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
            case .bottomMid: return CGPoint(x: r.midX, y: r.maxY)
            case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
            }
        }
        var inward: CGVector {
            switch self {
            case .topLeft: return CGVector(dx: 1, dy: 1)
            case .topMid: return CGVector(dx: 0, dy: 1)
            case .topRight: return CGVector(dx: -1, dy: 1)
            case .leftMid: return CGVector(dx: 1, dy: 0)
            case .rightMid: return CGVector(dx: -1, dy: 0)
            case .bottomLeft: return CGVector(dx: 1, dy: -1)
            case .bottomMid: return CGVector(dx: 0, dy: -1)
            case .bottomRight: return CGVector(dx: -1, dy: -1)
            }
        }
    }

    /// Eight notch markers per tile; the two aligned anchors become arrows pointing
    /// at each other.
    private func drawAnchors(for display: DisplaySnapshot, in rect: NSRect, active: (pos: AnchorPos, dir: CGVector)?) {
        let tile = rect.insetBy(dx: 1.5, dy: 1.5), r = tileCornerRadius
        // Inset the markers further inward than the reference bars / menu strip so they
        // never collide; corners move diagonally (their `inward` is (±1,±1)).
        let marginTile = tile.insetBy(dx: 24, dy: 24)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: tile, xRadius: r, yRadius: r).setClip()
        for pos in AnchorPos.allCases where active?.pos != pos {
            drawNotch(at: pos.point(in: marginTile), dir: pos.inward)
        }
        NSGraphicsContext.restoreGraphicsState()
        if let active { drawArrow(at: active.pos.point(in: marginTile), dir: active.dir) }
    }

    /// The active alignment marker(s), drawn large at *this* screen's real edges (in
    /// its own point coords) — the on-glass counterpart of the mini-map notches so the
    /// alignment is visible on the physical display too.
    private func drawScreenMarkers(_ markers: [CGDirectDisplayID: (pos: AnchorPos, dir: CGVector)]) {
        guard let me = centerID, let active = markers[me] else { return }
        // Inset from the screen edges (past the reference bars); dodge the notch on top.
        let notch = window?.screen?.safeAreaInsets.top ?? 0
        let area = NSRect(x: bounds.minX + 40, y: bounds.minY + 40 + notch,
                          width: bounds.width - 80, height: bounds.height - 80 - notch)
        drawArrow(at: active.pos.point(in: area), dir: active.dir, scale: 3)
    }

    /// Markers for the active alignment, read from the stored anchor pair; the
    /// facing side comes from the rendered rects.
    private func activeMarkers(_ rects: [CGDirectDisplayID: CGRect]) -> [CGDirectDisplayID: (pos: AnchorPos, dir: CGVector)] {
        guard let selID = selectedID, let sR = rects[selID] else { return [:] }
        if let a = activeV, let oR = rects[a.otherID] {
            let selLeft = sR.midX < oR.midX
            let sp = vPos(facingRight: selLeft, level: a.selfA), op = vPos(facingRight: !selLeft, level: a.otherA)
            return [selID: (sp, dirV(sp, corner: a.selfA != .center, partner: a.otherA)),
                    a.otherID: (op, dirV(op, corner: a.otherA != .center, partner: a.selfA))]
        }
        if let a = activeH, let oR = rects[a.otherID] {
            let selAbove = sR.midY < oR.midY
            let sp = hPos(facingBelow: selAbove, level: a.selfA), op = hPos(facingBelow: !selAbove, level: a.otherA)
            return [selID: (sp, dirH(sp, corner: a.selfA != .center, partner: a.otherA)),
                    a.otherID: (op, dirH(op, corner: a.otherA != .center, partner: a.selfA))]
        }
        return [:]
    }

    private func vPos(facingRight: Bool, level: VAnchor) -> AnchorPos {
        switch (facingRight, level) {
        case (true, .top): return .topRight
        case (true, .center): return .rightMid
        case (true, .bottom): return .bottomRight
        case (false, .top): return .topLeft
        case (false, .center): return .leftMid
        case (false, .bottom): return .bottomLeft
        }
    }
    private func hPos(facingBelow: Bool, level: HAnchor) -> AnchorPos {
        switch (facingBelow, level) {
        case (true, .left): return .bottomLeft
        case (true, .center): return .bottomMid
        case (true, .right): return .bottomRight
        case (false, .left): return .topLeft
        case (false, .center): return .topMid
        case (false, .right): return .topRight
        }
    }
    private func dirV(_ pos: AnchorPos, corner: Bool, partner: VAnchor) -> CGVector {
        if corner { return pos.inward }
        guard partner != .center else { return pos.inward }
        return CGVector(dx: pos.inward.dx, dy: partner == .top ? -1 : 1)
    }
    private func dirH(_ pos: AnchorPos, corner: Bool, partner: HAnchor) -> CGVector {
        if corner { return pos.inward }
        guard partner != .center else { return pos.inward }
        return CGVector(dx: partner == .left ? -1 : 1, dy: pos.inward.dy)
    }

    private func drawNotch(at p: CGPoint, dir: CGVector) {
        let n = unit(dir), len: CGFloat = 4
        let path = NSBezierPath()
        path.move(to: p); path.line(to: CGPoint(x: p.x + n.dx * len, y: p.y + n.dy * len))
        path.lineWidth = 2; path.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke(); path.stroke()
    }

    private func drawArrow(at p: CGPoint, dir: CGVector, scale: CGFloat = 1) {
        let inward = unit(dir), out = CGVector(dx: -inward.dx, dy: -inward.dy)
        let len: CGFloat = 7 * scale, half: CGFloat = 4 * scale
        let perp = CGVector(dx: -out.dy, dy: out.dx)
        let apex = CGPoint(x: p.x + out.dx * len, y: p.y + out.dy * len)
        let b1 = CGPoint(x: p.x + perp.dx * half, y: p.y + perp.dy * half)
        let b2 = CGPoint(x: p.x - perp.dx * half, y: p.y - perp.dy * half)
        let tri = NSBezierPath(); tri.move(to: apex); tri.line(to: b1); tri.line(to: b2); tri.close()
        NSColor.white.setFill(); tri.fill()
    }

    private func unit(_ v: CGVector) -> CGVector {
        let len = max(hypot(v.dx, v.dy), 0.001)
        return CGVector(dx: v.dx / len, dy: v.dy / len)
    }

    private func drawFooter(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 8), withAttributes: attrs)
    }

    private func drawCenteredMessage(_ message: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor]
        let size = (message as NSString).size(withAttributes: attrs)
        (message as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
