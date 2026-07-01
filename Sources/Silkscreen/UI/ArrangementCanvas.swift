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
    // The bottom button bar's views + state — constructed and driven in
    // ArrangementCanvas+Buttons.
    let feedButton = NSButton(title: "", target: nil, action: nil)
    let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
    /// Resolution slider (A ↔ a) for the selected display, in the bottom cluster.
    let resSlider = NSSlider()
    /// One/All scope toggle for the slider (single rectangle vs. overlapping rectangles).
    let scopeButton = NSButton(title: "", target: nil, action: nil)
    let buttonBar = NSVisualEffectView()

    /// The selected display's sorted modes, cached while the slider drives them so a
    /// live preview doesn't recompute per tick. Rebuilt in `syncButtons`.
    var sliderModes: [DisplayMode] = []

    /// The selected display's mode index at the moment a slider drag began, so `.all`
    /// scope can apply the same *step delta* to every display.
    var sliderDragStartIndex: Int?

    /// Base clearance above the screen bottom (before adding the Dock height): enough to
    /// clear a bottom-edge alignment arrow, but no more — the Dock inset is added on top.
    let baseBottomMargin: CGFloat = 40

    /// The button bar's bottom constraint, re-tuned in `layout()` to sit above the Dock.
    var buttonBarBottom: NSLayoutConstraint?

    init(state: ArrangementState, frame: NSRect) {
        self.state = state
        super.init(frame: frame)
        setupButtonBar()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// GPU-backed seam particles (CAEmitterLayer). Their simulation runs on the GPU, so
    /// no per-frame draw work or animation timer is needed — `draw(_:)` only repositions
    /// the emitters when the layout changes.
    private(set) lazy var seamEmitters: SeamEmitters = {
        wantsLayer = true
        let host = CALayer()
        // View is now a standard y-up NSView, matching CALayer's y-up geometry — no flip.
        host.frame = bounds
        host.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        host.zPosition = 1               // particles above the schematic fill
        layer?.addSublayer(host)
        return SeamEmitters(host: host)
    }()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { seamEmitters.clear() }
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
    var onSetResolutions: (([CGDirectDisplayID: CGDisplayMode], [CGDirectDisplayID: CGPoint]) -> Void)? { state.onSetResolutions }
    var onSetMirror: ((CGDirectDisplayID, CGDirectDisplayID) -> Void)? { state.onSetMirror }
    var onUnmirror: ((CGDirectDisplayID) -> Void)? { state.onUnmirror }
    var onCalibrate: ((CGDirectDisplayID) -> Void)? { state.onCalibrate }
    var onCalibrateVisual: ((CGDirectDisplayID) -> Void)? { state.onCalibrateVisual }
    var onResetCalibration: ((CGDirectDisplayID) -> Void)? { state.onResetCalibration }
    var onOpenAirPlaySettings: (() -> Void)? { state.onOpenAirPlaySettings }
    var onDismiss: (() -> Void)? { state.onDismiss }

    var airplaySession: AirPlaySession? { state.airplaySession }

    // Mouse drag state (local to the canvas handling the gesture).
    var draggedID: CGDirectDisplayID?
    var dragStartMouse: CGPoint = .zero
    var dragStartPhys: CGPoint = .zero    // dragged tile's physical origin at grab
    var dragTransform: Transform?         // frozen during a drag (stable cursor mapping)
    var dragMoved = false

    // Dragging the main display's menu-bar strip to move main to another tile.
    var draggingMenuBar: CGPoint?         // current cursor point while dragging

    // True while Option-dragging a tile: dropping onto another tile mirrors onto it.
    var optionMirrorDrag = false
    var mirrorDragPoint: CGPoint?         // cursor while Option-mirror dragging (drop target)

    // Keyboard continuous-move (nudge) state.
    var heldDirections: Set<MoveDirection> = []
    var moveTimer: Timer?
    var lastTick: CFTimeInterval = 0
    var nudgeAccum: CGPoint = .zero        // physical accumulator, like a cursor

    // One alignment step per ⌘⇧ press; commits when ⌘⇧ is released.
    var alignPending = false

    // Resolution preview flag (commits the pending mode when ⌘ is released).
    var zoomPending = false

    // Global (⌘⇧ ±) zoom run state. `globalZoomLevel` is a continuous, *unclamped* scale
    // applied to every display's starting PPI; each display picks the achievable mode
    // nearest `startPPI × level`, clamped to its range. Tracking the unclamped level (not
    // per-display detent positions) is what makes a maxed-out display stay pinned while
    // the level keeps rising, then rejoin proportionally as it falls. Reset each run.
    var globalZoomLevel: Double = 1
    var globalZoomStartPPI: [CGDirectDisplayID: Double] = [:]

    var showAlignGhosts: Bool { get { state.showAlignGhosts } set { state.showAlignGhosts = newValue } }

    /// The display this canvas's window sits on — its tile is centered in the view.
    /// nil ⇒ center the main display (single-window fallback).
    var centerID: CGDirectDisplayID?

    let outerPadding: CGFloat = 32
    let tileCornerRadius: CGFloat = 8

    /// Width of the right-hand column overlay (0 when it holds nothing). Home to both
    /// mirrored-display cards and a macOS-managed AirPlay session card.
    var mirrorColumnWidth: CGFloat {
        mirroredDisplays.isEmpty && airplaySession == nil ? 0 : 360
    }

    /// The un-mirror button rects from the most recent draw, per mirrored display id,
    /// for click hit-testing (view-local, so per-canvas).
    var unmirrorButtonRects: [CGDirectDisplayID: NSRect] = [:]

    /// The "Open Settings" button rect on the AirPlay card from the most recent draw,
    /// for click hit-testing. nil when no AirPlay card was drawn.
    var airplaySettingsButtonRect: NSRect?

    /// Cached native pixel aspect per display (see `nativeAspect`). Fixed per physical
    /// panel, so a stale entry for a disconnected id is harmless.
    var nativeAspectCache: [CGDirectDisplayID: Double?] = [:]

    /// Cached desktop wallpaper per display, keyed by (id, image URL) so a changed
    /// wallpaper reloads. `nil` value = looked up, none available.
    var wallpaperCache: [CGDirectDisplayID: (url: URL, image: NSImage)?] = [:]

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
    func predictedDockDisplay() -> CGDirectDisplayID? { state.predictedDockDisplay() }
    var mirroredDisplays: [DisplaySnapshot] { state.mirroredDisplays }
    var planeDisplays: [DisplaySnapshot] { state.planeDisplays }

    /// Commit the plane, then broadcast so every canvas redraws.
    func commitPlane() { state.commit() }

    /// Broadcast a plane change so every per-screen canvas redraws.
    func emitPreview() { state.notify() }

    // MARK: - View transform (fit the physical plane into the window)

    struct Transform {
        let scale: CGFloat            // view px per inch
        let offset: CGPoint
        let unionOrigin: CGPoint
        let viewHeight: CGFloat       // for the single plane→view y-flip

        // The physical plane is y-down (top-left origin, from `CGDisplayBounds`); this view
        // is a standard y-up NSView. Flip y exactly here — the one gate — so everything that
        // enters view space through `viewRect`/`viewPoint` (tiles, bars, particles, markers,
        // ghosts) is oriented correctly without any per-consumer flipping downstream.
        private func flipY(_ y: CGFloat) -> CGFloat { viewHeight - y }

        func viewRect(_ r: CGRect) -> CGRect {
            let x = offset.x + (r.minX - unionOrigin.x) * scale
            let yDown = offset.y + (r.minY - unionOrigin.y) * scale
            let h = r.height * scale
            // Flip the rect's *top* edge to a y-up bottom-left origin.
            return CGRect(x: x, y: flipY(yDown + h), width: r.width * scale, height: h)
        }
        func viewPoint(_ g: CGPoint) -> CGPoint {
            CGPoint(x: offset.x + (g.x - unionOrigin.x) * scale,
                    y: flipY(offset.y + (g.y - unionOrigin.y) * scale))
        }
    }

    func transform(_ rects: [CGDirectDisplayID: CGRect]) -> Transform? {
        let values = Array(rects.values)
        guard let first = values.first else { return nil }
        let union = values.dropFirst().reduce(first) { $0.union($1) }
        guard union.width > 0, union.height > 0 else { return nil }

        // Center the whole arrangement (the union) at the view midpoint — the same layout
        // on every screen, rather than pivoting each canvas around its own tile.
        let focus = CGPoint(x: union.midX, y: union.midY)

        // The mirror column overlays on the right; the plane stays centered in the full
        // bounds (not offset by the column), so mirroring doesn't shift the arrangement.
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
        return Transform(scale: scale, offset: offset, unionOrigin: union.origin, viewHeight: bounds.height)
    }
}
