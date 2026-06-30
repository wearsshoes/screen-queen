import AppKit

/// Interactive visualization + editor of the display arrangement.
///
/// Mouse: drag a tile to rearrange (magnetic snapping to edges + alignment
/// points; hold Shift to disable snapping). Keyboard (the clicked/selected
/// display): ⌘+arrows/WASD changes selection; arrows/WASD nudge continuously
/// (72 pt/s, Shift = 288); ⌘⇧+arrows/WASD steps through alignment snap points;
/// ⌘+/−/0 change resolution. Real displays are previewed during a manipulation
/// and reconfigured once on release (via onDragUpdate / onCommit).
final class ArrangementCanvas: NSView {

    var onCommit: (([CGDirectDisplayID: CGPoint]) -> Void)?
    /// Live preview of a prospective layout (drag/nudge/align/zoom) — drives the
    /// on-glass reference bars while keys/mouse are held.
    var onPreview: (([DisplaySnapshot]) -> Void)?
    var onSetMain: ((CGDirectDisplayID) -> Void)?
    var onSetMode: ((CGDirectDisplayID, CGDisplayMode) -> Void)?
    var onCalibrate: ((CGDirectDisplayID) -> Void)?
    var onCalibrateVisual: ((CGDirectDisplayID) -> Void)?
    var onResetCalibration: ((CGDirectDisplayID) -> Void)?

    private var displays: [DisplaySnapshot] = []
    private var colorFor: [CGDirectDisplayID: NSColor] = [:]
    private var selectedID: CGDirectDisplayID?

    /// Per-display origin overrides during a manipulation (global points).
    private var workingOrigins: [CGDirectDisplayID: CGPoint] = [:]

    // Mouse drag state.
    private var draggedID: CGDirectDisplayID?
    private var dragStartMouse: CGPoint = .zero
    private var dragStartOrigin: CGPoint = .zero
    private var dragMoved = false

    // Keyboard continuous-move state.
    private var heldDirections: Set<MoveDirection> = []
    private var moveTimer: Timer?
    private var lastTick: CFTimeInterval = 0
    /// Free (un-snapped) accumulator the autosolve resolves from, like a cursor.
    private var nudgeFree: CGPoint = .zero

    // Keyboard alignment state: one step per keypress, preview only; the layout
    // commits when ⌘⇧ is released. No auto-repeat (avoids queued steps).
    private var alignPending = false

    // Keyboard resolution state: one step per keypress, preview (incl. tile size
    // + reference bars) only; commits the chosen mode when ⌘ is released.
    private var pendingSize: [CGDirectDisplayID: CGSize] = [:]
    private var pendingMode: (id: CGDirectDisplayID, mode: CGDisplayMode)?
    private var zoomPending = false

    // Active alignment (for drawing anchor triangles).
    private var activeV: (selfA: VAnchor, otherA: VAnchor, otherID: CGDirectDisplayID)?
    private var activeH: (selfA: HAnchor, otherA: HAnchor, otherID: CGDirectDisplayID)?

    private let outerPadding: CGFloat = 32
    private let tileCornerRadius: CGFloat = 8

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func update(with displays: [DisplaySnapshot], colors: [CGDirectDisplayID: NSColor]) {
        self.displays = displays
        self.colorFor = colors
        workingOrigins.removeAll()
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

    // MARK: - Geometry

    private func effectiveBounds(_ d: DisplaySnapshot) -> CGRect {
        CGRect(origin: workingOrigins[d.id] ?? d.bounds.origin,
               size: pendingSize[d.id] ?? d.bounds.size)
    }

    private func effectiveSnapshot(_ d: DisplaySnapshot) -> DisplaySnapshot {
        d.with(bounds: effectiveBounds(d))
    }

    private func effectiveSnapshots() -> [DisplaySnapshot] { displays.map(effectiveSnapshot) }

    private struct Transform {
        let scale: CGFloat
        let offset: CGPoint
        let unionOrigin: CGPoint
        func viewRect(forGlobal r: CGRect) -> CGRect {
            CGRect(x: offset.x + (r.minX - unionOrigin.x) * scale,
                   y: offset.y + (r.minY - unionOrigin.y) * scale,
                   width: r.width * scale, height: r.height * scale)
        }
        func viewPoint(_ g: CGPoint) -> CGPoint {
            CGPoint(x: offset.x + (g.x - unionOrigin.x) * scale,
                    y: offset.y + (g.y - unionOrigin.y) * scale)
        }
    }

    private func currentTransform() -> Transform? {
        guard !displays.isEmpty else { return nil }
        let rects = displays.map(effectiveBounds)
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        guard union.width > 0, union.height > 0 else { return nil }
        let availW = bounds.width - outerPadding * 2
        let availH = bounds.height - outerPadding * 2
        let scale = min(availW / union.width, availH / union.height)
        let offset = CGPoint(x: outerPadding + (availW - union.width * scale) / 2,
                             y: outerPadding + (availH - union.height * scale) / 2)
        return Transform(scale: scale, offset: offset, unionOrigin: union.origin)
    }

    private func currentOrigins() -> [CGDirectDisplayID: CGPoint] {
        Dictionary(uniqueKeysWithValues: displays.map { ($0.id, effectiveBounds($0).origin) })
    }

    // MARK: - Physical layout (rendering)
    //
    // The point↔physical translation lives in `SchematicLayout`. The canvas owns
    // only the *view* transform (fitting the physical rects into the window) and
    // the interaction state; it builds a layout on demand from the effective
    // snapshots plus the live alignment intent.

    private func schematic() -> SchematicLayout {
        SchematicLayout(displays: effectiveSnapshots())
    }

    /// Push the prospective layout to the on-glass overlay so it tracks the
    /// manipulation; the overlay derives the same bars from these snapshots.
    private func emitPreview() {
        onPreview?(effectiveSnapshots())
    }

    private func physTransform(_ rects: [CGDirectDisplayID: CGRect]) -> Transform? {
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

    /// The display whose rendered (physical) tile contains view point `p`.
    private func display(at p: CGPoint) -> DisplaySnapshot? {
        let rects = schematic().rects
        guard let t = physTransform(rects) else { return nil }
        return displays.reversed().first { rects[$0.id].map { t.viewRect(forGlobal: $0).contains(p) } ?? false }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let d = display(at: p) else { return }
        draggedID = d.id
        selectedID = d.id
        dragStartMouse = p
        dragStartOrigin = effectiveBounds(d).origin
        dragMoved = false
        activeV = nil; activeH = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let id = draggedID, let dragged = displays.first(where: { $0.id == id }),
              let t = physTransform(schematic().rects) else { return }
        let p = convert(event.locationInWindow, from: nil)
        // Convert the cursor delta (view px) to a point delta so the physical tile
        // tracks the cursor 1:1: view → inches (÷ physical scale) → points
        // (× the display's points-per-inch).
        let ps = SchematicLayout.physSize(dragged)
        let pppX = dragged.bounds.width / max(ps.width, 0.01)
        let pppY = dragged.bounds.height / max(ps.height, 0.01)
        let free = CGPoint(x: dragStartOrigin.x + (p.x - dragStartMouse.x) / t.scale * pppX,
                           y: dragStartOrigin.y + (p.y - dragStartMouse.y) / t.scale * pppY)

        let snap = !event.modifierFlags.contains(.shift) // Shift cancels snapping
        let others = displays.filter { $0.id != id }
        let resolved = resolveDrag(size: dragged.bounds.size, free: free, others: others,
                                   scale: t.scale, dock: snap, align: snap, dragged: dragged)
        guard resolved != workingOrigins[id] else { return }
        workingOrigins[id] = resolved
        if abs(resolved.x - dragStartOrigin.x) > 0.5 || abs(resolved.y - dragStartOrigin.y) > 0.5 {
            dragMoved = true
        }
        needsDisplay = true
        if dragMoved { emitPreview() }
    }

    override func mouseUp(with event: NSEvent) {
        defer { draggedID = nil; dragMoved = false }
        guard draggedID != nil else { return }
        guard dragMoved else { needsDisplay = true; return }
        onCommit?(currentOrigins())
    }

    /// Resolve a free position to a logical placement. `dock` keeps the layout
    /// contiguous (flush to the nearest neighbor, no overlap/gap); `align`
    /// additionally magnet-snaps the slide along that edge to an alignment point.
    private func resolveDrag(size: CGSize, free: CGPoint, others: [DisplaySnapshot],
                             scale: CGFloat, dock: Bool, align: Bool,
                             dragged: DisplaySnapshot? = nil) -> CGPoint {
        activeV = nil; activeH = nil
        guard !others.isEmpty else { return free }
        guard dock else { return free } // fully free placement

        // 1) Autosolve: dock flush to the nearest neighbor without overlapping.
        var best = free
        var bestDist = CGFloat.greatestFiniteMagnitude
        var neighbor: DisplaySnapshot?
        var verticalSeam = true // a vertical seam ⇒ the free slide axis is Y
        for o in others {
            let ob = o.bounds
            let yA = clamp(free.y, ob.minY - size.height + 1, ob.maxY - 1)
            let xA = clamp(free.x, ob.minX - size.width + 1, ob.maxX - 1)
            let candidates: [(CGPoint, Bool)] = [
                (CGPoint(x: ob.maxX, y: yA), true),
                (CGPoint(x: ob.minX - size.width, y: yA), true),
                (CGPoint(x: xA, y: ob.maxY), false),
                (CGPoint(x: xA, y: ob.minY - size.height), false),
            ]
            for (c, vert) in candidates {
                let rect = CGRect(origin: c, size: size).insetBy(dx: 1, dy: 1)
                if others.contains(where: { $0.bounds.intersects(rect) }) { continue }
                let d = hypot(c.x - free.x, c.y - free.y)
                if d < bestDist { bestDist = d; best = c; neighbor = o; verticalSeam = vert }
            }
        }

        // 2) Snap the slide to the nearest of the seven alignment configs —
        //    measured in *physical* (schematic) space, which is what's drawn and
        //    dragged. Trial-place the docked candidate, read its rendered physical
        //    rect, and snap when one of its anchors comes within ~12 px of the
        //    neighbor's matching anchor. The committed origin stays the point
        //    value; ties (equal physical size) prefer the more central config.
        // Light magnet: snap the slide only when within a few view px of a
        // *physical* anchor offset; otherwise leave it continuous. `activeV/H`
        // record the snapped anchor purely so the tile markers can highlight it.
        if align, let o = neighbor, let dragged {
            let physScale = physTransform(SchematicLayout(displays: effectiveSnapshots()).rects)?.scale ?? scale
            let childSel = selIsChild(dragged.id, of: o.id)
            let threshold: CGFloat = 4 // view px
            if verticalSeam {
                let p2v = physScale * SchematicLayout.physSize(dragged).height / max(size.height, 1)
                var bestD = threshold
                for s in SchematicLayout.verticalSnaps(sel: dragged, other: o, selIsChild: childSel) {
                    let d = abs(s.value - best.y) * p2v
                    if d < bestD { bestD = d; best.y = s.value; activeV = (s.selfAnchor, s.otherAnchor, s.otherID) }
                }
            } else {
                let p2v = physScale * SchematicLayout.physSize(dragged).width / max(size.width, 1)
                var bestD = threshold
                for s in SchematicLayout.horizontalSnaps(sel: dragged, other: o, selIsChild: childSel) {
                    let d = abs(s.value - best.x) * p2v
                    if d < bestD { bestD = d; best.x = s.value; activeH = (s.selfAnchor, s.otherAnchor, s.otherID) }
                }
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
        let cmd = flags.contains(.command)
        let shift = flags.contains(.shift)

        if cmd, let ch = event.charactersIgnoringModifiers, "+=-_0".contains(ch) {
            if !event.isARepeat { handleResolutionKey(ch) } // one step per press
            return
        }
        guard let dir = direction(event) else { super.keyDown(with: event); return }

        if cmd && shift {
            guard !event.isARepeat else { return } // one step per press, no auto-repeat
            guard let id = selectedID else { NSSound.beep(); return }
            if workingOrigins[id] == nil, let d = displays.first(where: { $0.id == id }) {
                workingOrigins[id] = d.bounds.origin
            }
            stepAlignment(dir)
            alignPending = true
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
        if heldDirections.contains(dir) {
            heldDirections.remove(dir)
            if heldDirections.isEmpty {
                stopMoveTimer()
                onCommit?(currentOrigins())
            }
        }
    }

    /// Alignment commits when ⌘⇧ is released; resolution commits when ⌘ is
    /// released. Nothing commits while the modifiers are held.
    override func flagsChanged(with event: NSEvent) {
        let f = event.modifierFlags
        if alignPending, !(f.contains(.command) && f.contains(.shift)) {
            alignPending = false
            needsDisplay = true
            onCommit?(currentOrigins())
        }
        if zoomPending, !f.contains(.command) {
            zoomPending = false
            let mode = pendingMode
            pendingMode = nil
            pendingSize.removeAll()
            if let mode { onSetMode?(mode.id, mode.mode) }
        }
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        if moveTimer != nil { stopMoveTimer(); onCommit?(currentOrigins()) }
        if alignPending { alignPending = false; onCommit?(currentOrigins()) }
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

    private func beginContinuousMoveIfNeeded() {
        guard moveTimer == nil, let id = selectedID,
              let d = displays.first(where: { $0.id == id }) else { return }
        if workingOrigins[id] == nil { workingOrigins[id] = d.bounds.origin }
        nudgeFree = workingOrigins[id]!
        activeV = nil; activeH = nil
        lastTick = CACurrentMediaTime()
        moveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.moveTick()
        }
    }

    private func stopMoveTimer() {
        moveTimer?.invalidate()
        moveTimer = nil
    }

    /// Move the free accumulator, then autosolve to a logical docked position —
    /// same resolver as dragging, so nudging keeps the layout contiguous and
    /// jumps to the next valid slot rather than separating the screens. Canvas-
    /// only preview; the hardware reconfigures once on key release.
    private func moveTick() {
        guard let id = selectedID, !heldDirections.isEmpty,
              let sel = displays.first(where: { $0.id == id }) else { stopMoveTimer(); return }
        let now = CACurrentMediaTime()
        let dt = CGFloat(now - lastTick); lastTick = now
        let rate: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 288 : 72
        var dx: CGFloat = 0, dy: CGFloat = 0
        if heldDirections.contains(.left) { dx -= 1 }
        if heldDirections.contains(.right) { dx += 1 }
        if heldDirections.contains(.up) { dy -= 1 }   // global space is y-down
        if heldDirections.contains(.down) { dy += 1 }
        nudgeFree.x += dx * rate * dt
        nudgeFree.y += dy * rate * dt

        let others = displays.filter { $0.id != id }
        let scale = currentTransform()?.scale ?? 1
        // Nudge autosolves (stays contiguous) but does NOT alignment-snap.
        workingOrigins[id] = resolveDrag(size: sel.bounds.size, free: nudgeFree,
                                         others: others, scale: scale, dock: true, align: false)
        needsDisplay = true
        emitPreview()
    }

    private func moveSelection(_ dir: MoveDirection) {
        guard !displays.isEmpty else { return }
        let cur = displays.first(where: { $0.id == selectedID }) ?? displays[0]
        selectedID = cur.id
        let c = center(of: cur)
        let candidates = displays.filter { $0.id != cur.id }.filter {
            let oc = center(of: $0)
            switch dir {
            case .left: return oc.x < c.x - 1
            case .right: return oc.x > c.x + 1
            case .up: return oc.y < c.y - 1
            case .down: return oc.y > c.y + 1
            }
        }
        if let best = candidates.min(by: {
            hypot(center(of: $0).x - c.x, center(of: $0).y - c.y)
                < hypot(center(of: $1).x - c.x, center(of: $1).y - c.y)
        }) {
            selectedID = best.id
            activeV = nil; activeH = nil
            needsDisplay = true
        }
    }

    private struct Join {
        let other: DisplaySnapshot
        let vertical: Bool   // true: vertical seam (displays side by side)
        let aPositive: Bool  // selected is on the +axis side (right / below) of other
    }

    /// The current docking of the selected display against a neighbor, if any.
    private func currentJoin(_ a: DisplaySnapshot) -> Join? {
        let A = effectiveBounds(a)
        let tol: CGFloat = 2
        for o in displays where o.id != a.id {
            let O = effectiveBounds(o)
            let yOverlap = min(A.maxY, O.maxY) - max(A.minY, O.minY)
            let xOverlap = min(A.maxX, O.maxX) - max(A.minX, O.minX)
            if abs(A.minX - O.maxX) <= tol, yOverlap > tol { return Join(other: o, vertical: true, aPositive: true) }
            if abs(A.maxX - O.minX) <= tol, yOverlap > tol { return Join(other: o, vertical: true, aPositive: false) }
            if abs(A.minY - O.maxY) <= tol, xOverlap > tol { return Join(other: o, vertical: false, aPositive: true) }
            if abs(A.maxY - O.minY) <= tol, xOverlap > tol { return Join(other: o, vertical: false, aPositive: false) }
        }
        return nil
    }

    /// One alignment step. Along the shared seam, cycle the alignment snaps and
    /// stop at the extreme (no wraparound). Pressing *into* the neighbor re-docks
    /// to the nearer perpendicular edge so you can walk around the corner.
    private func stepAlignment(_ dir: MoveDirection) {
        guard let sel = displays.first(where: { $0.id == selectedID }) else { return }
        let others = displays.filter { $0.id != sel.id }
        guard !others.isEmpty else { return }

        guard let join = currentJoin(sel) else {
            cycleAlign(sel, against: others, vertical: dir.isVertical,
                       increasing: dir == .down || dir == .right)
            return
        }
        if join.vertical {
            if dir.isVertical {
                cycleAlign(sel, against: [join.other], vertical: true, increasing: dir == .down)
            } else if dir == (join.aPositive ? .left : .right) {
                redock(sel, around: join.other, seamVertical: true)
            }
        } else {
            if !dir.isVertical {
                cycleAlign(sel, against: [join.other], vertical: false, increasing: dir == .right)
            } else if dir == (join.aPositive ? .up : .down) {
                redock(sel, around: join.other, seamVertical: false)
            }
        }
        emitPreview()
    }

    private func cycleAlign(_ sel: DisplaySnapshot, against others: [DisplaySnapshot],
                            vertical: Bool, increasing: Bool) {
        let s = effectiveBounds(sel)
        guard let o = others.min(by: {
            hypot(center(of: $0).x - s.midX, center(of: $0).y - s.midY)
                < hypot(center(of: $1).x - s.midX, center(of: $1).y - s.midY)
        }) else { return }
        let step = increasing ? 1 : -1
        let childSel = selIsChild(sel.id, of: o.id)

        // The seven physical-anchor offsets are distinct point values (even for
        // equal-point-width screens), already in spatial order, so cycling is
        // just stepping the index and stopping at the extremes.
        if vertical {
            let snaps = SchematicLayout.verticalSnaps(sel: effectiveSnapshot(sel), other: effectiveSnapshot(o), selIsChild: childSel)
            guard !snaps.isEmpty else { return }
            let cur = activeV?.otherID == o.id
                ? (snaps.firstIndex { $0.selfAnchor == activeV!.selfA && $0.otherAnchor == activeV!.otherA } ?? nearestIndex(snaps.map(\.value), s.minY))
                : nearestIndex(snaps.map(\.value), s.minY)
            let t = snaps[max(0, min(snaps.count - 1, cur + step))]
            workingOrigins[sel.id] = CGPoint(x: s.minX, y: t.value)
            activeV = (t.selfAnchor, t.otherAnchor, o.id); activeH = nil
        } else {
            let snaps = SchematicLayout.horizontalSnaps(sel: effectiveSnapshot(sel), other: effectiveSnapshot(o), selIsChild: childSel)
            guard !snaps.isEmpty else { return }
            let cur = activeH?.otherID == o.id
                ? (snaps.firstIndex { $0.selfAnchor == activeH!.selfA && $0.otherAnchor == activeH!.otherA } ?? nearestIndex(snaps.map(\.value), s.minX))
                : nearestIndex(snaps.map(\.value), s.minX)
            let t = snaps[max(0, min(snaps.count - 1, cur + step))]
            workingOrigins[sel.id] = CGPoint(x: t.value, y: s.minY)
            activeH = (t.selfAnchor, t.otherAnchor, o.id); activeV = nil
        }
        needsDisplay = true
    }

    /// Index of the value nearest `current` (used to seed cycling from the live,
    /// possibly-unsnapped position).
    private func nearestIndex(_ values: [CGFloat], _ current: CGFloat) -> Int {
        var bestI = 0, bestD = CGFloat.greatestFiniteMagnitude
        for (i, v) in values.enumerated() where abs(v - current) < bestD { bestD = abs(v - current); bestI = i }
        return bestI
    }

    /// Whether `a` is rendered as the BFS child of the pair (a, b) — its density
    /// governs the seam, so snap targets must be computed with it.
    private func selIsChild(_ a: CGDirectDisplayID, of b: CGDirectDisplayID) -> Bool {
        let p = schematic().parents
        if p[a] == b { return true }
        if p[b] == a { return false }
        return !(displays.first { $0.id == a }?.isMain ?? false)
    }

    /// Re-dock the selected display onto the nearer perpendicular edge of `o`
    /// (centered), letting alignment "turn the corner".
    private func redock(_ sel: DisplaySnapshot, around o: DisplaySnapshot, seamVertical: Bool) {
        let s = effectiveBounds(sel), O = effectiveBounds(o)
        var origin = s.origin
        if seamVertical {
            origin.x = O.midX - s.width / 2
            origin.y = (s.midY <= O.midY) ? (O.minY - s.height) : O.maxY
            activeH = (.center, .center, o.id); activeV = nil
        } else {
            origin.y = O.midY - s.height / 2
            origin.x = (s.midX <= O.midX) ? (O.minX - s.width) : O.maxX
            activeV = (.center, .center, o.id); activeH = nil
        }
        workingOrigins[sel.id] = origin
        needsDisplay = true
    }

    /// Step the selected display's resolution. Like alignment, this only sets a
    /// pending mode and previews (tile size + reference bars); the real mode is
    /// applied when ⌘ is released (see `flagsChanged`).
    private func handleResolutionKey(_ ch: String) {
        guard let id = selectedID, let display = displays.first(where: { $0.id == id }) else {
            NSSound.beep(); return
        }
        let modes = modesList(for: display)
            .sorted { $0.pointWidth * $0.pointHeight < $1.pointWidth * $1.pointHeight }
        guard !modes.isEmpty else { return }

        // Current = the in-progress pending mode if any, else the live mode.
        let currentMode = (pendingMode?.id == id ? pendingMode?.mode : nil) ?? CGDisplayCopyDisplayMode(id)
        let idx = modes.firstIndex { currentMode != nil && ModeCatalog.sameMode(currentMode!, $0.cgMode) }

        var target: DisplayMode?
        switch ch {
        case "=", "+": // zoom in: fewer points (larger UI)
            target = idx.map { $0 - 1 >= 0 ? modes[$0 - 1] : modes.first } ?? modes.first
        case "-", "_": // zoom out: more points (more space)
            target = idx.map { $0 + 1 < modes.count ? modes[$0 + 1] : modes.last } ?? modes.last
        case "0":
            target = defaultMode(modes)
        default: break
        }
        guard let t = target else { return }

        guard let sel = displays.first(where: { $0.id == id }) else { return }
        let oldBounds = effectiveBounds(sel) // before applying the new size
        let newSize = CGSize(width: t.pointWidth, height: t.pointHeight)

        pendingMode = (id, t.cgMode)
        pendingSize[id] = newSize
        zoomPending = true

        // Preserve the existing alignment at the new size if there was one;
        // otherwise just re-dock so the layout stays contiguous.
        if let p = preservedAlignment(sel: sel, oldBounds: oldBounds, newSize: newSize) {
            workingOrigins[id] = p.origin
            activeV = p.v; activeH = p.h
        } else {
            let others = displays.filter { $0.id != id }
            let scale = currentTransform()?.scale ?? 1
            workingOrigins[id] = resolveDrag(size: newSize, free: oldBounds.origin,
                                             others: others, scale: scale, dock: true, align: false)
            activeV = nil; activeH = nil
        }

        needsDisplay = true
        emitPreview()
    }

    /// If the selected display is currently docked *and* sitting on one of its
    /// alignment snaps, recompute the position that keeps the same anchor pairing
    /// at `newSize` (and the markers to show it). Returns nil otherwise.
    private func preservedAlignment(sel: DisplaySnapshot, oldBounds: CGRect, newSize: CGSize)
        -> (origin: CGPoint, v: (VAnchor, VAnchor, CGDirectDisplayID)?, h: (HAnchor, HAnchor, CGDirectDisplayID)?)? {
        guard let join = currentJoin(sel) else { return nil }
        let other = effectiveSnapshot(join.other)
        let O = effectiveBounds(join.other)
        let childSel = selIsChild(sel.id, of: join.other.id)
        let newChild = sel.with(bounds: CGRect(origin: oldBounds.origin, size: newSize))
        if join.vertical {
            let old = SchematicLayout.verticalSnaps(sel: sel.with(bounds: oldBounds), other: other, selIsChild: childSel)
            guard let match = old.first(where: { abs($0.value - oldBounds.minY) < 1.5 }) else { return nil }
            let now = SchematicLayout.verticalSnaps(sel: newChild, other: other, selIsChild: childSel)
            guard let nw = now.first(where: { $0.selfAnchor == match.selfAnchor && $0.otherAnchor == match.otherAnchor }) else { return nil }
            let x = join.aPositive ? O.maxX : O.minX - newSize.width
            return (CGPoint(x: x, y: nw.value), (nw.selfAnchor, nw.otherAnchor, nw.otherID), nil)
        } else {
            let old = SchematicLayout.horizontalSnaps(sel: sel.with(bounds: oldBounds), other: other, selIsChild: childSel)
            guard let match = old.first(where: { abs($0.value - oldBounds.minX) < 1.5 }) else { return nil }
            let now = SchematicLayout.horizontalSnaps(sel: newChild, other: other, selIsChild: childSel)
            guard let nw = now.first(where: { $0.selfAnchor == match.selfAnchor && $0.otherAnchor == match.otherAnchor }) else { return nil }
            let y = join.aPositive ? O.maxY : O.minY - newSize.height
            return (CGPoint(x: nw.value, y: y), nil, (nw.selfAnchor, nw.otherAnchor, nw.otherID))
        }
    }

    /// Whether to show the built-in display's full (extended) resolution set.
    var extendedBuiltinModes = false

    /// Selectable modes for a display. The built-in defaults to the standard
    /// scaled set (HiDPI 2× modes) unless extended options are enabled.
    private func modesList(for d: DisplaySnapshot) -> [DisplayMode] {
        let all = ModeCatalog.menuModes(for: d.id)
        if d.isBuiltin && !extendedBuiltinModes {
            let standard = all.filter { $0.pixelWidth == 2 * $0.pointWidth }
            return standard.isEmpty ? all : standard
        }
        return all
    }

    /// macOS "Default": native pixels at 2× (HiDPI), not the most-space 1× mode.
    private func defaultMode(_ modes: [DisplayMode]) -> DisplayMode? {
        let retina = modes.filter { abs($0.pixelWidth - 2 * $0.pointWidth) <= 1 }
        return (retina.isEmpty ? modes : retina)
            .max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
    }

    private func center(of d: DisplaySnapshot) -> CGPoint {
        let b = effectiveBounds(d)
        return CGPoint(x: b.midX, y: b.midY)
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        if let d = display(at: p) {
            let menu = NSMenu()
            menu.addItem(withTitle: d.name, action: nil, keyEquivalent: "")
            menu.addItem(.separator())

            let mainItem = NSMenuItem(title: "Set as Main Display",
                                      action: #selector(setMainFromMenu(_:)), keyEquivalent: "")
            mainItem.target = self
            mainItem.representedObject = NSNumber(value: d.id)
            mainItem.isEnabled = !d.isMain
            menu.addItem(mainItem)

            menu.addItem(resolutionMenuItem(for: d))
            menu.addItem(.separator())
            if displays.count > 1 {
                let matchItem = NSMenuItem(title: "Calibrate by Matching…",
                                           action: #selector(calibrateVisualFromMenu(_:)), keyEquivalent: "")
                matchItem.target = self
                matchItem.representedObject = NSNumber(value: d.id)
                menu.addItem(matchItem)
            }
            let calItem = NSMenuItem(title: "Calibrate by Diagonal…",
                                     action: #selector(calibrateFromMenu(_:)), keyEquivalent: "")
            calItem.target = self
            calItem.representedObject = NSNumber(value: d.id)
            menu.addItem(calItem)

            if d.physicalSizeIsCalibrated {
                let resetItem = NSMenuItem(title: "Reset Size to EDID",
                                           action: #selector(resetCalibrationFromMenu(_:)), keyEquivalent: "")
                resetItem.target = self
                resetItem.representedObject = NSNumber(value: d.id)
                menu.addItem(resetItem)
            }
            return menu
        }
        return nil
    }

    private func resolutionMenuItem(for d: DisplaySnapshot) -> NSMenuItem {
        let item = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = CGDisplayCopyDisplayMode(d.id)
        for mode in modesList(for: d) {
            let mi = NSMenuItem(title: mode.label, action: #selector(setModeFromMenu(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = ModeChoice(id: d.id, mode: mode.cgMode)
            if let current, ModeCatalog.sameMode(current, mode.cgMode) { mi.state = .on }
            submenu.addItem(mi)
        }
        item.submenu = submenu
        return item
    }

    private final class ModeChoice {
        let id: CGDirectDisplayID
        let mode: CGDisplayMode
        init(id: CGDirectDisplayID, mode: CGDisplayMode) { self.id = id; self.mode = mode }
    }

    @objc private func setMainFromMenu(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        onSetMain?(n.uint32Value)
    }
    @objc private func setModeFromMenu(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? ModeChoice else { return }
        onSetMode?(c.id, c.mode)
    }
    @objc private func calibrateFromMenu(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        onCalibrate?(n.uint32Value)
    }
    @objc private func calibrateVisualFromMenu(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        onCalibrateVisual?(n.uint32Value)
    }
    @objc private func resetCalibrationFromMenu(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        onResetCalibration?(n.uint32Value)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        let layout = schematic()
        let rects = layout.rects
        guard let t = physTransform(rects) else {
            drawCenteredMessage("No displays detected")
            return
        }

        for d in displays {
            if let r = rects[d.id] { drawTile(for: d, in: t.viewRect(forGlobal: r)) }
        }
        drawReferenceBars(layout.bars, t: t)
        let markers = activeMarkers(rects)
        for d in displays {
            if let r = rects[d.id] { drawAnchors(for: d, in: t.viewRect(forGlobal: r), active: markers[d.id]) }
        }
        drawFooter("Drag to rearrange · ⌘/arrows select · arrows nudge · ⌘⇧ align · ⌘ ± 0 resolution")
    }

    /// Reference bars at each seam, from the shared `SchematicLayout`: a bar on
    /// each side of the seam in the *facing* display's color, length = 10cm
    /// (anchored to the main screen) capped to the overlap. The on-glass overlay
    /// renders the same `SeamBar`s, so the mini-map and the glass agree.
    private func drawReferenceBars(_ bars: [SeamBar], t: Transform) {
        guard !bars.isEmpty else { return }
        let thickness: CGFloat = 5

        for bar in bars {
            // The window's physical length on each screen (same point size, so the
            // physical lengths differ by density — the size change the bar shows).
            // Each bar sits at its own clamped (on-screen) position along the seam.
            let lenA = bar.physLenInchesA * t.scale // a's side, facing color b
            let lenB = bar.physLenInchesB * t.scale // b's side, facing color a
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

        color.withAlphaComponent(selected ? 0.28 : 0.15).setFill()
        path.fill()
        color.withAlphaComponent(selected ? 1.0 : 0.7).setStroke()
        path.lineWidth = selected ? 3 : 1.5
        path.stroke()

        drawLabel(for: display, in: inset)
    }

    private func drawLabel(for display: DisplaySnapshot, in rect: NSRect) {
        var lines: [(String, NSFont, NSColor)] = []
        lines.append((display.name + (display.isMain ? "  ●" : ""), .boldSystemFont(ofSize: 12), .labelColor))

        // Effective resolution, live during a zoom and italic while uncommitted.
        let eb = effectiveBounds(display)
        let pending = pendingMode?.id == display.id ? pendingMode?.mode : nil
        let pixelW = pending?.pixelWidth ?? Int(display.pixelSize.width)
        let pixelH = pending?.pixelHeight ?? Int(display.pixelSize.height)
        let pts = "\(Int(eb.width))×\(Int(eb.height)) pt"
        let px = "\(pixelW)×\(pixelH) px"
        let resText = pixelW > Int(eb.width) ? "\(pts)  (HiDPI \(px))" : pts
        let resFont: NSFont = pending != nil
            ? NSFontManager.shared.convert(.systemFont(ofSize: 10), toHaveTrait: .italicFontMask)
            : .systemFont(ofSize: 10)
        lines.append((resText, resFont, .labelColor))

        // EDID is trustworthy for the built-in or once calibrated; otherwise
        // prompt to calibrate (coworking monitors often report bogus sizes).
        let trusted = display.physicalSizeIsCalibrated || display.isBuiltin
        if let ppi = display.ppi, trusted {
            let cal = display.physicalSizeIsCalibrated ? " (calibrated)" : ""
            lines.append((String(format: "%.0f ppi · %.1f″%@", ppi, display.diagonalInches, cal),
                          .systemFont(ofSize: 10), .labelColor))
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

        /// Inward direction (toward the tile center), y-down. Diagonal for
        /// corners, perpendicular for edge midpoints.
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

    /// Eight notch markers (short lines perpendicular to their edge, touching the
    /// outline) per tile. The single anchor on each of the two aligned displays
    /// becomes an inward-pointing arrow; a center anchor paired with a corner is
    /// tilted to 45° to match.
    private func drawAnchors(for display: DisplaySnapshot, in rect: NSRect,
                             active: (pos: AnchorPos, dir: CGVector)?) {
        let color = colorFor[display.id] ?? .systemGray
        let tile = rect.insetBy(dx: 1.5, dy: 1.5)
        let r = tileCornerRadius

        // Notches, clipped to the rounded tile so they never poke outside it.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: tile, xRadius: r, yRadius: r).setClip()
        for pos in AnchorPos.allCases where active?.pos != pos {
            drawNotch(at: notchPoint(pos, in: tile, radius: r), dir: pos.inward, color: color)
        }
        NSGraphicsContext.restoreGraphicsState()

        // The active anchor on each aligned display: an arrow pointing outward,
        // toward the other display (so the two arrows point at each other).
        if let active {
            drawArrow(at: active.pos.point(in: tile), dir: active.dir, color: color)
        }
    }

    /// Pull corner anchors inward along the diagonal by the corner radius so the
    /// notch sits inside the rounded corner rather than at the clipped tip.
    private func notchPoint(_ pos: AnchorPos, in r: NSRect, radius: CGFloat) -> CGPoint {
        let p = pos.point(in: r)
        let inward = pos.inward
        if abs(inward.dx) > 0, abs(inward.dy) > 0 { // corner
            let n = unit(inward)
            return CGPoint(x: p.x + n.dx * radius, y: p.y + n.dy * radius)
        }
        return p
    }

    /// Markers for the active alignment. They read the same stored anchor pair the
    /// physical layout was placed by (`vAnchorPair`/`hAnchorPair` use it too), so
    /// the arrows always land on the anchors the tiles were docked on. Facing side
    /// (which edge the arrow sits on) comes from the rendered rects.
    private func activeMarkers(_ rects: [CGDirectDisplayID: CGRect])
        -> [CGDirectDisplayID: (pos: AnchorPos, dir: CGVector)] {
        guard let selID = selectedID, let sR = rects[selID] else { return [:] }

        if let a = activeV, let oR = rects[a.otherID] { // vertical seam (side by side)
            let selLeft = sR.midX < oR.midX
            let sp = vPos(facingRight: selLeft, level: a.selfA)
            let op = vPos(facingRight: !selLeft, level: a.otherA)
            return [selID: (sp, dirV(sp, corner: a.selfA != .center, partner: a.otherA)),
                    a.otherID: (op, dirV(op, corner: a.otherA != .center, partner: a.selfA))]
        }
        if let a = activeH, let oR = rects[a.otherID] { // horizontal seam (stacked)
            let selAbove = sR.midY < oR.midY
            let sp = hPos(facingBelow: selAbove, level: a.selfA)
            let op = hPos(facingBelow: !selAbove, level: a.otherA)
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
        // Center on a side edge; tilt to 45° toward a corner partner.
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
        path.move(to: p)
        path.line(to: CGPoint(x: p.x + n.dx * len, y: p.y + n.dy * len))
        path.lineWidth = 2.5
        path.lineCapStyle = .round
        color.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    /// An arrow pointing *outward* (toward the other display), base on the edge.
    private func drawArrow(at p: CGPoint, dir: CGVector, color: NSColor) {
        let inward = unit(dir)
        let out = CGVector(dx: -inward.dx, dy: -inward.dy)
        let len: CGFloat = 11, half: CGFloat = 6
        let perp = CGVector(dx: -out.dy, dy: out.dx)
        let apex = CGPoint(x: p.x + out.dx * len, y: p.y + out.dy * len)
        let b1 = CGPoint(x: p.x + perp.dx * half, y: p.y + perp.dy * half)
        let b2 = CGPoint(x: p.x - perp.dx * half, y: p.y - perp.dy * half)
        let tri = NSBezierPath()
        tri.move(to: apex); tri.line(to: b1); tri.line(to: b2); tri.close()
        color.setFill(); tri.fill()
        NSColor.white.setStroke(); tri.lineWidth = 1.5; tri.stroke()
    }

    private func unit(_ v: CGVector) -> CGVector {
        let len = max(hypot(v.dx, v.dy), 0.001)
        return CGVector(dx: v.dx / len, dy: v.dy / len)
    }

    private func drawFooter(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2,
                                            y: bounds.height - size.height - 8), withAttributes: attrs)
    }

    private func drawCenteredMessage(_ message: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = (message as NSString).size(withAttributes: attrs)
        (message as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2,
                                               y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
