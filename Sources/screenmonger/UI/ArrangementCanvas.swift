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

    // MARK: - Mouse / dragging

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let t = currentTransform() else { return }
        let p = convert(event.locationInWindow, from: nil)
        for d in displays.reversed() where t.viewRect(forGlobal: effectiveBounds(d)).contains(p) {
            draggedID = d.id
            selectedID = d.id
            dragStartMouse = p
            dragStartOrigin = effectiveBounds(d).origin
            dragMoved = false
            activeV = nil; activeH = nil
            needsDisplay = true
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let id = draggedID, let t = currentTransform(),
              let dragged = displays.first(where: { $0.id == id }) else { return }
        let p = convert(event.locationInWindow, from: nil)
        let free = CGPoint(x: dragStartOrigin.x + (p.x - dragStartMouse.x) / t.scale,
                           y: dragStartOrigin.y + (p.y - dragStartMouse.y) / t.scale)

        let snap = !event.modifierFlags.contains(.shift) // Shift cancels snapping
        let others = displays.filter { $0.id != id }
        let resolved = resolveDrag(size: dragged.bounds.size, free: free, others: others,
                                   scale: t.scale, dock: snap, align: snap)
        guard resolved != workingOrigins[id] else { return }
        workingOrigins[id] = resolved
        if abs(resolved.x - dragStartOrigin.x) > 0.5 || abs(resolved.y - dragStartOrigin.y) > 0.5 {
            dragMoved = true
        }
        needsDisplay = true
        if dragMoved { onPreview?(effectiveSnapshots()) }
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
                             scale: CGFloat, dock: Bool, align: Bool) -> CGPoint {
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

        // 2) Snap the slide along the shared edge to an alignment point (magnetic),
        //    clamped so the displays keep overlapping.
        let threshold: CGFloat = 12 / scale
        if align, let o = neighbor {
            if verticalSeam {
                let lo = o.bounds.minY - size.height + 1, hi = o.bounds.maxY - 1
                var bestDY = threshold
                for s in Snapping.verticalAligns(selectedHeight: size.height, others: [o]) {
                    let v = clamp(s.value, lo, hi)
                    let d = abs(v - best.y)
                    if d < bestDY { bestDY = d; best.y = v; activeV = (s.selfAnchor, s.otherAnchor, s.otherID) }
                }
            } else {
                let lo = o.bounds.minX - size.width + 1, hi = o.bounds.maxX - 1
                var bestDX = threshold
                for s in Snapping.horizontalAligns(selectedWidth: size.width, others: [o]) {
                    let v = clamp(s.value, lo, hi)
                    let d = abs(v - best.x)
                    if d < bestDX { bestDX = d; best.x = v; activeH = (s.selfAnchor, s.otherAnchor, s.otherID) }
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
        onPreview?(effectiveSnapshots())
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
        onPreview?(effectiveSnapshots())
    }

    private func cycleAlign(_ sel: DisplaySnapshot, against others: [DisplaySnapshot],
                            vertical: Bool, increasing: Bool) {
        let s = effectiveBounds(sel)
        if vertical {
            let snaps = Snapping.verticalAligns(selectedHeight: s.height, others: others).sorted { $0.value < $1.value }
            guard let t = nextSnap(snaps, value: { $0.value }, current: s.minY, increasing: increasing) else { return }
            workingOrigins[sel.id] = CGPoint(x: s.minX, y: t.value)
            activeV = (t.selfAnchor, t.otherAnchor, t.otherID); activeH = nil
        } else {
            let snaps = Snapping.horizontalAligns(selectedWidth: s.width, others: others).sorted { $0.value < $1.value }
            guard let t = nextSnap(snaps, value: { $0.value }, current: s.minX, increasing: increasing) else { return }
            workingOrigins[sel.id] = CGPoint(x: t.value, y: s.minY)
            activeH = (t.selfAnchor, t.otherAnchor, t.otherID); activeV = nil
        }
        needsDisplay = true
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

    /// Next snap strictly beyond `current` in the given direction, or nil at the
    /// extreme (no wraparound).
    private func nextSnap<T>(_ snaps: [T], value: (T) -> CGFloat, current: CGFloat, increasing: Bool) -> T? {
        if increasing { return snaps.first(where: { value($0) > current + 0.5 }) }
        return snaps.last(where: { value($0) < current - 0.5 })
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
        onPreview?(effectiveSnapshots())
    }

    /// If the selected display is currently docked *and* sitting on one of its
    /// alignment snaps, recompute the position that keeps the same anchor pairing
    /// at `newSize` (and the markers to show it). Returns nil otherwise.
    private func preservedAlignment(sel: DisplaySnapshot, oldBounds: CGRect, newSize: CGSize)
        -> (origin: CGPoint, v: (VAnchor, VAnchor, CGDirectDisplayID)?, h: (HAnchor, HAnchor, CGDirectDisplayID)?)? {
        guard let join = currentJoin(sel) else { return nil }
        let O = effectiveBounds(join.other)
        if join.vertical {
            let old = Snapping.verticalAligns(selectedHeight: oldBounds.height, others: [join.other])
            guard let match = old.first(where: { abs($0.value - oldBounds.minY) < 1.5 }) else { return nil }
            let now = Snapping.verticalAligns(selectedHeight: newSize.height, others: [join.other])
            guard let nw = now.first(where: { $0.selfAnchor == match.selfAnchor && $0.otherAnchor == match.otherAnchor }) else { return nil }
            let x = join.aPositive ? O.maxX : O.minX - newSize.width
            return (CGPoint(x: x, y: nw.value), (nw.selfAnchor, nw.otherAnchor, nw.otherID), nil)
        } else {
            let old = Snapping.horizontalAligns(selectedWidth: oldBounds.width, others: [join.other])
            guard let match = old.first(where: { abs($0.value - oldBounds.minX) < 1.5 }) else { return nil }
            let now = Snapping.horizontalAligns(selectedWidth: newSize.width, others: [join.other])
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
        guard let t = currentTransform() else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        for d in displays.reversed() where t.viewRect(forGlobal: effectiveBounds(d)).contains(p) {
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

        guard let t = currentTransform() else {
            drawCenteredMessage("No displays detected")
            return
        }

        for d in displays {
            drawTile(for: d, in: t.viewRect(forGlobal: effectiveBounds(d)))
        }
        drawReferenceBars(t)
        let markers = activeMarkers()
        for d in displays {
            drawAnchors(for: d, in: t.viewRect(forGlobal: effectiveBounds(d)), active: markers[d.id])
        }
        drawFooter("Drag to rearrange · ⌘/arrows select · arrows nudge · ⌘⇧ align · ⌘ ± 0 resolution")
    }

    /// Reference bars at each seam, mirroring the on-glass overlay: a bar on each
    /// side of the seam in the *facing* display's color, length = 10cm (anchored
    /// to the main screen) capped to the overlap — so the size comparison shows
    /// in the mini-map too.
    private func drawReferenceBars(_ t: Transform) {
        let eff = effectiveSnapshots()
        let junctions = DisplayGraph.junctions(eff)
        guard !junctions.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: eff.map { ($0.id, $0) })
        let refPPT = eff.first(where: { $0.isMain })?.pointsPerInch
            ?? eff.compactMap { $0.pointsPerInch }.first ?? 100
        let refPoints = CGFloat(10.0 / 2.54 * refPPT)
        let thickness: CGFloat = 5

        // Each screen renders the same point-length, so its physical size scales
        // as mainPPT / thatScreen'sPPT — mirror that in the map.
        func barLen(_ ppt: Double?, capPoints: CGFloat) -> CGFloat {
            let physical = refPoints * CGFloat(refPPT / (ppt ?? refPPT))
            return min(physical, capPoints) * t.scale
        }

        for j in junctions {
            guard let a = byID[j.aID], let b = byID[j.bID] else { continue }
            let overlap = j.isVertical
                ? min(a.bounds.maxY, b.bounds.maxY) - max(a.bounds.minY, b.bounds.minY)
                : min(a.bounds.maxX, b.bounds.maxX) - max(a.bounds.minX, b.bounds.minX)
            let cap = overlap * 0.9
            let lenA = barLen(a.pointsPerInch, capPoints: cap) // a's side, facing color b
            let lenB = barLen(b.pointsPerInch, capPoints: cap) // b's side, facing color a
            let c = t.viewPoint(CGPoint(x: j.isVertical ? j.line : j.midpoint,
                                        y: j.isVertical ? j.midpoint : j.line))
            if j.isVertical {
                drawBar(NSRect(x: c.x - thickness, y: c.y - lenA / 2, width: thickness, height: lenA), colorFor[j.bID])
                drawBar(NSRect(x: c.x, y: c.y - lenB / 2, width: thickness, height: lenB), colorFor[j.aID])
            } else {
                drawBar(NSRect(x: c.x - lenA / 2, y: c.y - thickness, width: lenA, height: thickness), colorFor[j.bID])
                drawBar(NSRect(x: c.x - lenB / 2, y: c.y, width: lenB, height: thickness), colorFor[j.aID])
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
        var lines: [(String, NSFont)] = []
        lines.append((display.name + (display.isMain ? "  ●" : ""), .boldSystemFont(ofSize: 12)))

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
        lines.append((resText, resFont))

        if let ppi = display.ppi {
            let suffix = display.physicalSizeIsCalibrated
                ? String(format: " (calibrated %.0f\")", display.diagonalInches) : ""
            lines.append((String(format: "%.0f ppi%@", ppi, suffix), .systemFont(ofSize: 10)))
        } else {
            lines.append(("ppi: unknown (needs calibration)", .systemFont(ofSize: 10)))
        }
        var y = rect.minY + 8
        for (text, font) in lines {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
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

    /// Which anchor (and arrow direction) is active on each of the two aligned
    /// displays. The aligned anchor sits on the edge facing the other display.
    private func activeMarkers() -> [CGDirectDisplayID: (pos: AnchorPos, dir: CGVector)] {
        guard let selID = selectedID, let s = displays.first(where: { $0.id == selID }) else { return [:] }
        let sR = effectiveBounds(s)

        if let a = activeV, let o = displays.first(where: { $0.id == a.otherID }) {
            let oRight = effectiveBounds(o).midX > sR.midX
            let sp = vPos(facingRight: oRight, level: a.selfA)
            let op = vPos(facingRight: !oRight, level: a.otherA)
            return [selID: (sp, dirV(sp, corner: a.selfA != .center, partner: a.otherA)),
                    a.otherID: (op, dirV(op, corner: a.otherA != .center, partner: a.selfA))]
        }
        if let a = activeH, let o = displays.first(where: { $0.id == a.otherID }) {
            let oBelow = effectiveBounds(o).midY > sR.midY
            let sp = hPos(facingBelow: oBelow, level: a.selfA)
            let op = hPos(facingBelow: !oBelow, level: a.otherA)
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
