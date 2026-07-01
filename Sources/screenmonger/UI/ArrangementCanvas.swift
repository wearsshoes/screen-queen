import AppKit

/// Interactive visualization + editor of the display arrangement.
///
/// The schematic is drawn at true physical sizes. While the user manipulates it
/// (drag / keyboard), a **physical plane** — `plane`, a rect per display in inches
/// — is the source of truth: dragging moves a rect on the plane 1:1 with the
/// cursor, and snapping/alignment are physical. Only when the manipulation ends
/// (mouse up / modifier released) do we convert the plane back to a macOS *point*
/// arrangement (via `SchematicLayout.pointArrangement`) and commit. The point↔
/// physical seam map is thus applied at exactly two boundaries — interpret the
/// committed layout onto the plane, convert the plane back — never per frame.
///
/// Keys (selected display): ⌘+arrows/WASD change selection; arrows/WASD nudge;
/// ⌘⇧+arrows/WASD step alignment; ⌘ +/−/0 change resolution.
final class ArrangementCanvas: NSView {

    var onCommit: (([CGDirectDisplayID: CGPoint]) -> Void)?
    var onPreview: (([DisplaySnapshot]) -> Void)?
    var onSetMain: ((CGDirectDisplayID) -> Void)?
    var onSetMode: ((CGDirectDisplayID, CGDisplayMode) -> Void)?
    var onCalibrate: ((CGDirectDisplayID) -> Void)?
    var onCalibrateVisual: ((CGDirectDisplayID) -> Void)?
    var onResetCalibration: ((CGDirectDisplayID) -> Void)?

    private var displays: [DisplaySnapshot] = []
    private var colorFor: [CGDirectDisplayID: NSColor] = [:]
    private var selectedID: CGDirectDisplayID?

    /// Physical rects (inches) while manipulating. Empty ⇒ not manipulating.
    private var plane: [CGDirectDisplayID: CGRect] = [:]

    // Mouse drag state.
    private var draggedID: CGDirectDisplayID?
    private var dragStartMouse: CGPoint = .zero
    private var dragStartPhys: CGPoint = .zero    // dragged tile's physical origin at grab
    private var dragTransform: Transform?         // frozen during a drag (stable cursor mapping)
    private var dragMoved = false

    // Keyboard continuous-move (nudge) state.
    private var heldDirections: Set<MoveDirection> = []
    private var moveTimer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var nudgeAccum: CGPoint = .zero        // physical accumulator, like a cursor

    // One alignment step per ⌘⇧ press; commits when ⌘⇧ is released.
    private var alignPending = false

    // Resolution: pending mode/size preview; commits the mode when ⌘ is released.
    private var pendingSize: [CGDirectDisplayID: CGSize] = [:]
    private var pendingMode: (id: CGDirectDisplayID, mode: CGDisplayMode)?
    private var zoomPending = false

    // Active alignment anchors, for the tile arrow markers.
    private var activeV: (selfA: VAnchor, otherA: VAnchor, otherID: CGDirectDisplayID)?
    private var activeH: (selfA: HAnchor, otherA: HAnchor, otherID: CGDirectDisplayID)?

    /// Whether to show the built-in display's full (extended) resolution set.
    var extendedBuiltinModes = false

    private let outerPadding: CGFloat = 32
    private let tileCornerRadius: CGFloat = 8

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func update(with displays: [DisplaySnapshot], colors: [CGDirectDisplayID: NSColor]) {
        self.displays = displays
        self.colorFor = colors
        // Interpret point→physical only when the OS layout genuinely diverges from
        // the plane — first load, hotplug, calibration, or an external rearrange.
        // Our own committed changes round-trip to the same arrangement, so we keep
        // the plane (no interpret, no round-trip drift).
        if !planeMatches(displays) {
            plane = SchematicLayout(displays: displays).rects
        }
        pendingSize.removeAll()
        pendingMode = nil
        zoomPending = false
        draggedID = nil
        if let sel = selectedID, !displays.contains(where: { $0.id == sel }) {
            selectedID = nil; activeV = nil; activeH = nil
        }
        if selectedID == nil {
            selectedID = displays.first(where: { $0.isMain })?.id ?? displays.first?.id
        }
        needsDisplay = true
    }

    /// Whether the plane already represents `snapshot` (same displays + physical
    /// sizes, and it converts back to the same point arrangement). If so we keep
    /// the plane rather than re-interpreting.
    private func planeMatches(_ snapshot: [DisplaySnapshot]) -> Bool {
        guard !plane.isEmpty, Set(snapshot.map(\.id)) == Set(plane.keys) else { return false }
        for d in snapshot {
            let ps = SchematicLayout.physSize(d)
            guard let r = plane[d.id], abs(r.width - ps.width) < 0.05, abs(r.height - ps.height) < 0.05 else { return false }
        }
        let ours = SchematicLayout.pointArrangement(rects: plane, displays: snapshot)
        for d in snapshot {
            guard let o = ours[d.id], abs(o.x - d.bounds.minX) < 1.5, abs(o.y - d.bounds.minY) < 1.5 else { return false }
        }
        return true
    }

    // MARK: - Physical / point helpers

    /// Effective point size (live during a zoom preview).
    private func pointSize(_ d: DisplaySnapshot) -> CGSize { pendingSize[d.id] ?? d.bounds.size }

    /// Displays with the effective point size applied (physical size unchanged).
    private func effDisplays() -> [DisplaySnapshot] {
        displays.map { $0.with(bounds: CGRect(origin: $0.bounds.origin, size: pointSize($0))) }
    }

    /// The plane is the persistent source of truth — render straight from it.
    private func currentRects() -> [CGDirectDisplayID: CGRect] { plane }
    private func currentBars() -> [SeamBar] { SchematicLayout.seamBars(effDisplays(), rects: plane) }

    /// Convert the plane to a point arrangement and commit. The plane stays put;
    /// our commit round-trips, so the next `update` keeps it (see `planeMatches`).
    private func commitPlane() {
        guard !plane.isEmpty else { return }
        onCommit?(SchematicLayout.pointArrangement(rects: plane, displays: effDisplays()))
    }

    /// Push the prospective layout to the on-glass overlay (as point snapshots).
    private func emitPreview() {
        let origins = SchematicLayout.pointArrangement(rects: currentRects(), displays: effDisplays())
        let snaps = effDisplays().map { $0.movedTo(origin: origins[$0.id] ?? $0.bounds.origin) }
        onPreview?(snaps)
    }

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
        let availW = bounds.width - outerPadding * 2, availH = bounds.height - outerPadding * 2
        let scale = min(availW / union.width, availH / union.height)
        let offset = CGPoint(x: outerPadding + (availW - union.width * scale) / 2,
                             y: outerPadding + (availH - union.height * scale) / 2)
        return Transform(scale: scale, offset: offset, unionOrigin: union.origin)
    }

    // MARK: - Mouse / dragging

    private func display(at p: CGPoint) -> DisplaySnapshot? {
        let rects = currentRects()
        guard let t = transform(rects) else { return nil }
        return displays.reversed().first { rects[$0.id].map { t.viewRect($0).contains(p) } ?? false }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let d = display(at: p), plane[d.id] != nil else { return }
        draggedID = d.id
        selectedID = d.id
        dragStartMouse = p
        dragTransform = transform(plane)      // freeze so the cursor mapping is stable
        dragStartPhys = plane[d.id]?.origin ?? .zero
        dragMoved = false
        activeV = nil; activeH = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let id = draggedID, let dragged = displays.first(where: { $0.id == id }),
              let t = dragTransform ?? transform(plane) else { return }
        let p = convert(event.locationInWindow, from: nil)
        // The tile tracks the cursor 1:1: view delta ÷ scale = physical delta.
        let free = CGPoint(x: dragStartPhys.x + (p.x - dragStartMouse.x) / t.scale,
                           y: dragStartPhys.y + (p.y - dragStartMouse.y) / t.scale)
        let snap = !event.modifierFlags.contains(.shift) // Shift cancels docking/snapping
        let resolved = dockAndSnap(dragged, free: free, scale: t.scale, snap: snap)
        guard resolved != plane[id]?.origin else { return }
        plane[id] = CGRect(origin: resolved, size: SchematicLayout.physSize(dragged))
        dragMoved = true
        needsDisplay = true
        emitPreview()
    }

    override func mouseUp(with event: NSEvent) {
        defer { draggedID = nil; dragMoved = false; dragTransform = nil }
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
            needsDisplay = true
            commitPlane()
        }
        if zoomPending, !f.contains(.command) {
            zoomPending = false
            let mode = pendingMode
            pendingMode = nil; pendingSize.removeAll() // plane rebuilds on the resulting update
            if let mode { onSetMode?(mode.id, mode.mode) }
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
            needsDisplay = true
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
        needsDisplay = true
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
        needsDisplay = true
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
        if d.isBuiltin && !extendedBuiltinModes {
            let standard = all.filter { $0.pixelWidth == 2 * $0.pointWidth }
            return standard.isEmpty ? all : standard
        }
        return all
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

        let mainItem = NSMenuItem(title: "Set as Main Display", action: #selector(setMainFromMenu(_:)), keyEquivalent: "")
        mainItem.target = self; mainItem.representedObject = NSNumber(value: d.id); mainItem.isEnabled = !d.isMain
        menu.addItem(mainItem)

        menu.addItem(resolutionMenuItem(for: d))
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
        item.submenu = submenu
        return item
    }

    private final class ModeChoice {
        let id: CGDirectDisplayID; let mode: CGDisplayMode
        init(id: CGDirectDisplayID, mode: CGDisplayMode) { self.id = id; self.mode = mode }
    }

    @objc private func setMainFromMenu(_ s: NSMenuItem) { (s.representedObject as? NSNumber).map { onSetMain?($0.uint32Value) } }
    @objc private func setModeFromMenu(_ s: NSMenuItem) { (s.representedObject as? ModeChoice).map { onSetMode?($0.id, $0.mode) } }
    @objc private func calibrateFromMenu(_ s: NSMenuItem) { (s.representedObject as? NSNumber).map { onCalibrate?($0.uint32Value) } }
    @objc private func calibrateVisualFromMenu(_ s: NSMenuItem) { (s.representedObject as? NSNumber).map { onCalibrateVisual?($0.uint32Value) } }
    @objc private func resetCalibrationFromMenu(_ s: NSMenuItem) { (s.representedObject as? NSNumber).map { onResetCalibration?($0.uint32Value) } }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        let rects = currentRects()
        guard let t = dragTransform ?? transform(rects) else {
            drawCenteredMessage("No displays detected")
            return
        }
        for d in displays where rects[d.id] != nil { drawTile(for: d, in: t.viewRect(rects[d.id]!)) }
        drawReferenceBars(currentBars(), t: t)
        let markers = activeMarkers(rects)
        for d in displays where rects[d.id] != nil { drawAnchors(for: d, in: t.viewRect(rects[d.id]!), active: markers[d.id]) }
        drawFooter("Drag to rearrange · ⌘/arrows select · arrows nudge · ⌘⇧ align · ⌘ ± 0 resolution")
    }

    /// Reference bars at each seam, from the shared `SchematicLayout`: a window
    /// 100% of the smaller screen's edge shown on each side in the facing color, at
    /// its own physical size (differs by density), each clamped to stay on-screen.
    private func drawReferenceBars(_ bars: [SeamBar], t: Transform) {
        let thickness: CGFloat = 5
        for bar in bars {
            let lenA = bar.physLenInchesA * t.scale, lenB = bar.physLenInchesB * t.scale
            if bar.isVertical {
                let cA = t.viewPoint(CGPoint(x: bar.physLine, y: bar.physAlongA))
                let cB = t.viewPoint(CGPoint(x: bar.physLine, y: bar.physAlongB))
                drawBar(NSRect(x: cA.x - thickness, y: cA.y - lenA / 2, width: thickness, height: lenA), colorFor[bar.bID])
                drawBar(NSRect(x: cB.x, y: cB.y - lenB / 2, width: thickness, height: lenB), colorFor[bar.aID])
            } else {
                let cA = t.viewPoint(CGPoint(x: bar.physAlongA, y: bar.physLine))
                let cB = t.viewPoint(CGPoint(x: bar.physAlongB, y: bar.physLine))
                drawBar(NSRect(x: cA.x - lenA / 2, y: cA.y - thickness, width: lenA, height: thickness), colorFor[bar.bID])
                drawBar(NSRect(x: cB.x - lenB / 2, y: cB.y, width: lenB, height: thickness), colorFor[bar.aID])
            }
        }
    }

    private func drawBar(_ rect: NSRect, _ color: NSColor?) {
        (color ?? .systemGray).withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    }

    private func drawTile(for display: DisplaySnapshot, in rect: NSRect) {
        let color = colorFor[display.id] ?? .systemGray
        let selected = display.id == selectedID
        let inset = rect.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: tileCornerRadius, yRadius: tileCornerRadius)
        color.withAlphaComponent(selected ? 0.28 : 0.15).setFill(); path.fill()
        color.withAlphaComponent(selected ? 1.0 : 0.7).setStroke()
        path.lineWidth = selected ? 3 : 1.5; path.stroke()
        drawLabel(for: display, in: inset)
    }

    private func drawLabel(for display: DisplaySnapshot, in rect: NSRect) {
        var lines: [(String, NSFont, NSColor)] = []
        lines.append((display.name + (display.isMain ? "  ●" : ""), .boldSystemFont(ofSize: 12), .labelColor))

        // Effective resolution, live during a zoom and italic while uncommitted.
        let sz = pointSize(display)
        let pending = pendingMode?.id == display.id ? pendingMode?.mode : nil
        let pixelW = pending?.pixelWidth ?? Int(display.pixelSize.width)
        let pixelH = pending?.pixelHeight ?? Int(display.pixelSize.height)
        let pts = "\(Int(sz.width))×\(Int(sz.height)) pt"
        let px = "\(pixelW)×\(pixelH) px"
        let resText = pixelW > Int(sz.width) ? "\(pts)  (HiDPI \(px))" : pts
        let resFont: NSFont = pending != nil
            ? NSFontManager.shared.convert(.systemFont(ofSize: 10), toHaveTrait: .italicFontMask)
            : .systemFont(ofSize: 10)
        lines.append((resText, resFont, .labelColor))

        let trusted = display.physicalSizeIsCalibrated || display.isBuiltin
        if let ppi = display.ppi, trusted {
            let cal = display.physicalSizeIsCalibrated ? " (calibrated)" : ""
            lines.append((String(format: "%.0f ppi · %.1f″%@", ppi, display.diagonalInches, cal), .systemFont(ofSize: 10), .labelColor))
        } else if let ppi = display.ppi {
            lines.append((String(format: "%.0f ppi · calibrate screen size?", ppi), .systemFont(ofSize: 10), .labelColor))
        } else {
            lines.append(("calibrate screen size?", .systemFont(ofSize: 10), .labelColor))
        }

        var y = rect.minY + 8
        for (text, font, color) in lines {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (text as NSString).size(withAttributes: attrs)
            guard y + size.height <= rect.maxY - 4 else { break }
            (text as NSString).draw(at: CGPoint(x: rect.minX + 8, y: y), withAttributes: attrs)
            y += size.height + 2
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
        let color = colorFor[display.id] ?? .systemGray
        let tile = rect.insetBy(dx: 1.5, dy: 1.5), r = tileCornerRadius
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: tile, xRadius: r, yRadius: r).setClip()
        for pos in AnchorPos.allCases where active?.pos != pos {
            drawNotch(at: notchPoint(pos, in: tile, radius: r), dir: pos.inward, color: color)
        }
        NSGraphicsContext.restoreGraphicsState()
        if let active { drawArrow(at: active.pos.point(in: tile), dir: active.dir, color: color) }
    }

    private func notchPoint(_ pos: AnchorPos, in r: NSRect, radius: CGFloat) -> CGPoint {
        let p = pos.point(in: r), inward = pos.inward
        if abs(inward.dx) > 0, abs(inward.dy) > 0 {
            let n = unit(inward)
            return CGPoint(x: p.x + n.dx * radius, y: p.y + n.dy * radius)
        }
        return p
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

    private func drawNotch(at p: CGPoint, dir: CGVector, color: NSColor) {
        let n = unit(dir), len: CGFloat = 6
        let path = NSBezierPath()
        path.move(to: p); path.line(to: CGPoint(x: p.x + n.dx * len, y: p.y + n.dy * len))
        path.lineWidth = 2.5; path.lineCapStyle = .round
        color.withAlphaComponent(0.9).setStroke(); path.stroke()
    }

    private func drawArrow(at p: CGPoint, dir: CGVector, color: NSColor) {
        let inward = unit(dir), out = CGVector(dx: -inward.dx, dy: -inward.dy)
        let len: CGFloat = 11, half: CGFloat = 6
        let perp = CGVector(dx: -out.dy, dy: out.dx)
        let apex = CGPoint(x: p.x + out.dx * len, y: p.y + out.dy * len)
        let b1 = CGPoint(x: p.x + perp.dx * half, y: p.y + perp.dy * half)
        let b2 = CGPoint(x: p.x - perp.dx * half, y: p.y - perp.dy * half)
        let tri = NSBezierPath(); tri.move(to: apex); tri.line(to: b1); tri.line(to: b2); tri.close()
        color.setFill(); tri.fill()
        NSColor.white.setStroke(); tri.lineWidth = 1.5; tri.stroke()
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
