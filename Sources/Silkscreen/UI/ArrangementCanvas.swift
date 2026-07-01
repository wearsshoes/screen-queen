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
        doneButton.target = self; doneButton.action = #selector(doneTapped)
        doneButton.keyEquivalent = "\r"   // primary action → renders blue (default button)
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
    var displays: [DisplaySnapshot] { get { state.displays } set { state.displays = newValue } }
    var selectedID: CGDirectDisplayID? { get { state.selectedID } set { state.selectedID = newValue } }
    var plane: [CGDirectDisplayID: CGRect] { get { state.plane } set { state.plane = newValue } }
    var pendingSize: [CGDirectDisplayID: CGSize] { get { state.pendingSize } set { state.pendingSize = newValue } }
    var pendingMode: (id: CGDirectDisplayID, mode: CGDisplayMode)? { get { state.pendingMode } set { state.pendingMode = newValue } }
    var activeV: (selfA: VAnchor, otherA: VAnchor, otherID: CGDirectDisplayID)? { get { state.activeV } set { state.activeV = newValue } }
    var activeH: (selfA: HAnchor, otherA: HAnchor, otherID: CGDirectDisplayID)? { get { state.activeH } set { state.activeH = newValue } }
    var extendedBuiltinModes: Bool { get { state.extendedBuiltinModes } set { state.extendedBuiltinModes = newValue } }

    // Convenience forwards to the shared callbacks.
    var onCommit: (([CGDirectDisplayID: CGPoint]) -> Void)? { state.onCommit }
    var onSetMain: ((CGDirectDisplayID) -> Void)? { state.onSetMain }
    var onSetResolution: ((CGDirectDisplayID, CGDisplayMode, [CGDirectDisplayID: CGPoint]) -> Void)? { state.onSetResolution }
    var onCalibrate: ((CGDirectDisplayID) -> Void)? { state.onCalibrate }
    var onCalibrateVisual: ((CGDirectDisplayID) -> Void)? { state.onCalibrateVisual }
    var onResetCalibration: ((CGDirectDisplayID) -> Void)? { state.onResetCalibration }
    var onDismiss: (() -> Void)? { state.onDismiss }

    // Mouse drag state (local to the canvas handling the gesture).
    var draggedID: CGDirectDisplayID?
    var dragStartMouse: CGPoint = .zero
    var dragStartPhys: CGPoint = .zero    // dragged tile's physical origin at grab
    var dragTransform: Transform?         // frozen during a drag (stable cursor mapping)
    var dragMoved = false

    // Dragging the main display's menu-bar strip to move main to another tile.
    var draggingMenuBar: CGPoint?         // current cursor point while dragging

    // Keyboard continuous-move (nudge) state.
    var heldDirections: Set<MoveDirection> = []
    var moveTimer: Timer?
    var lastTick: CFTimeInterval = 0
    var nudgeAccum: CGPoint = .zero        // physical accumulator, like a cursor

    // One alignment step per ⌘⇧ press; commits when ⌘⇧ is released.
    var alignPending = false

    // Resolution preview flag (commits the pending mode when ⌘ is released).
    var zoomPending = false

    var showAlignGhosts: Bool { get { state.showAlignGhosts } set { state.showAlignGhosts = newValue } }

    /// The display this canvas's window sits on — its tile is centered in the view.
    /// nil ⇒ center the main display (single-window fallback).
    var centerID: CGDirectDisplayID?

    let outerPadding: CGFloat = 32
    let tileCornerRadius: CGFloat = 8

    /// Cached native pixel aspect per display (see `nativeAspect`). Fixed per physical
    /// panel, so a stale entry for a disconnected id is harmless.
    var nativeAspectCache: [CGDirectDisplayID: Double?] = [:]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // Handle clicks even when this window isn't key (no activate-first click).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Called by the state after a mutation so this view repaints.
    func refresh() { syncButtons(); needsDisplay = true }

    func pointSize(_ d: DisplaySnapshot) -> CGSize { state.pointSize(d) }
    func sizedDisplays() -> [DisplaySnapshot] { state.sizedDisplays() }
    func currentRects() -> [CGDirectDisplayID: CGRect] { plane }
    func currentBars() -> [SeamBar] { state.currentBars() }
    func seamColors(_ bars: [SeamBar]) -> [DisplayGraph.SeamKey: NSColor] { state.seamColors(bars) }

    /// Commit the plane, then broadcast so every canvas redraws.
    func commitPlane() { state.commit() }

    /// Broadcast a plane change so every per-screen canvas redraws.
    func emitPreview() { state.notify() }

    // MARK: - View transform (fit the physical plane into the window)

    struct Transform {
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

    func transform(_ rects: [CGDirectDisplayID: CGRect]) -> Transform? {
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
}
