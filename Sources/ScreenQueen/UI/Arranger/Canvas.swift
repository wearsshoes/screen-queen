import AppKit
import SwiftUI

/// Interactive visualization + editor of the display arrangement.
///
/// The schematic is drawn at true physical sizes. While the user manipulates it, a
/// **physical plane** (`plane`, a rect per display in inches) is the source of truth;
/// only when the manipulation ends is the plane converted back to a macOS *point*
/// arrangement (`SchematicLayout.toPoints`) and committed. The point↔physical map is
/// applied at exactly those two boundaries, never per frame.
///
/// Keys: ⌘+arrows/WASD change selection; arrows/WASD nudge; ⌘⇧+arrows/WASD step
/// alignment; ⌘ +/−/0 change resolution.
final class Canvas: NSView {

    /// One coordinate system everywhere: the plane is y-down (`CGDisplayBounds`), the
    /// SwiftUI Canvas and gestures are y-down, so the view is too — no flip gates.
    override var isFlipped: Bool { true }

    /// Shared editing state — one instance across every per-screen canvas.
    let state: ArrangerState

    /// The bottom button bar — a SwiftUI island (see ButtonBarView), hosted per
    /// canvas and rebuilt from state in `updateBar`.
    var barHost: NSHostingView<ButtonBarView>?
    /// The chromeTileScale the bar last rendered at (set by renderChrome's pass).
    var barScale: CGFloat = 1
    /// The bar control under the real cursor, reported by the bar island's `.onHover`
    /// (SwiftUI owns the hit-testing) — the active canvas's value drives every
    /// canvas's ghost tooltip.
    var hoveredBarControl: BarControl?

    /// The selected display's sorted modes, cached while the slider drives them.
    var sliderModes: [DisplayMode] = []

    /// Mode index at slider-drag start, so `.all` scope applies the same step delta everywhere.
    var sliderDragStartIndex: Int?

    /// Clearance above the screen bottom before the Dock inset is added.
    let baseBottomMargin: CGFloat = 40

    /// The cap rule: narrowest screen minus breathing room, floored so pathological
    /// screens degrade to a slightly-overflowing bar instead of a constraint brawl.
    static func barWidthCap(minScreenWidth: CGFloat) -> CGFloat {
        max(320, minScreenWidth - 64)
    }

    /// The instruction line under the bar (see `FooterView`), scaled/positioned with it.
    var footerHost: FooterHost?

    /// Ghost-mapping state for `ghostPoint` (the ghost mouse + tooltip): this canvas's
    /// minimap scale ÷ the active canvas's, and the active canvas's centre. Recomputed
    /// in `renderChrome` on active-screen change.
    var ghostArrow: GhostCursorLayer?
    var ghostScale: CGFloat = 1
    var ghostActiveCenter: CGPoint = .zero
    /// True while this canvas shows the pink ghost chrome (cursor is on another screen).
    var isGhost = false
    /// The beacon: a pulsing pink map-pin at the cursor's location on this canvas's tiles.
    var planeMarkerLayer: PlaneMouseMarkerLayer?

    /// The frosted info card per display (see `LabelCard`) — a real backdrop-blur subview,
    /// repositioned to the tile each frame; created on demand, hidden when untouched.
    var labelCards: [CGDirectDisplayID: LabelCardHost] = [:]

    /// The right-hand mirror/AirPlay column (see `MirrorColumn`); created on demand.
    var mirrorColumn: MirrorColumnHost?

    /// Fired at the end of `layout()`, once `bounds` is final, so the chrome re-renders
    /// with the settled size.
    var onLayout: (() -> Void)?

    /// The fun tooltip bubble — shown on *every* canvas at the mirrored cursor position.
    var tooltipBubble: TooltipHost?

    /// The top-of-screen countdown banner — built on demand in CountdownBanner.swift.
    /// The first SwiftUI island: an NSHostingView subview on the canvas.
    var banner: NSHostingView<CountdownBannerView>?
    /// The banner's top constraint, re-tuned in `layout()` to clear the menu bar.
    var bannerTop: NSLayoutConstraint?

    /// The schematic renderer — a SwiftUI Canvas island (see SchematicCanvas.swift),
    /// below every effect layer/subview (added first, default z). Click-through; this
    /// view keeps all input handling.
    private(set) var schematicHost: SchematicCanvasHost!
    private var schematicGeneration = 0

    /// Repaint the schematic — the Canvas-era `needsDisplay = true`.
    func repaintSchematic() {
        schematicGeneration += 1
        schematicHost.rootView = SchematicCanvasView(canvas: self, generation: schematicGeneration)
    }

    init(state: ArrangerState, frame: NSRect) {
        self.state = state
        super.init(frame: frame)
        let host = SchematicCanvasHost(rootView: SchematicCanvasView(canvas: self, generation: 0))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)   // first subview — everything else composites above
        schematicHost = host
        setupButtonBar()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// GPU-backed seam particles (CAEmitterLayer) — no per-frame draw work or timer;
    /// `draw(_:)` only repositions the emitters when the layout changes.
    private(set) lazy var seamEmitters: SeamEmitters = {
        wantsLayer = true
        let host = CALayer()
        host.frame = bounds
        host.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        host.zPosition = 1               // particles above the schematic fill
        layer?.addSublayer(host)
        return SeamEmitters(host: host)
    }()

    /// The front seam glow — above the sparkle emitters (the wide soft glow is drawn
    /// behind them, in `draw(_:)`).
    private(set) lazy var seamGlow: SeamGlow = {
        wantsLayer = true
        let host = CALayer()
        host.frame = bounds
        host.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        host.zPosition = 2
        layer?.addSublayer(host)
        return SeamGlow(host: host)
    }()

    /// The floating "what she sees" panel (see SolvePanel), on its own layer above the
    /// seam layers. Draggable; body click-through.
    private(set) lazy var solvePanel: SolvePanelHost = {
        let p = SolvePanelHost(rootView: SolvePanelView(content: SolvePanelContent()))
        p.frame = NSRect(origin: .zero, size: NSSize(width: 240, height: 166))
        p.wantsLayer = true
        p.layer?.zPosition = 3
        // A drag stores the panel's centre as an inch offset from the screen centre —
        // its own state (moving a tile never moves it), scaling with the minimap.
        p.onMoved = { [weak self] origin in
            guard let self, let t = self.drawTransform(self.currentRects()), t.scale > 0 else { return }
            let centre = CGPoint(x: origin.x + p.frame.width / 2, y: origin.y + p.frame.height / 2)
            self.state.solvePanelCenterOffsetInches = CGPoint(
                x: (centre.x - self.bounds.midX) / t.scale,
                y: (centre.y - self.bounds.midY) / t.scale)
            self.state.notify()
        }
        addSubview(p)
        return p
    }()

    /// The granny panel's natural size in points, at `chromeTileScale == 1`.
    static let panelNaturalSize = CGSize(width: 208, height: 144)

    /// Place a *map-relative* chrome element: size = `naturalSize × chromeTileScale`
    /// (rides the tiles), centre = `bounds.mid + offset × transform.scale`. The offset is
    /// in **plane inches** (the schematic's physical unit, shown shrunk on the map) — NOT
    /// real on-glass inches. Same map-relative spot on every canvas.
    /// Places the granny viewer, the button bar, and the footer.
    func chromeViewRect(naturalSize: CGSize, centreOffsetInches off: CGPoint) -> CGRect? {
        guard let t = drawTransform(currentRects()), t.scale > 0 else { return nil }
        let k = chromeTileScale(t)
        return chromeViewRect(finalSize: CGSize(width: naturalSize.width * k,
                                                height: naturalSize.height * k),
                              centreOffsetInches: off, in: t)
    }

    /// The `finalSize` variant, for chrome laid out at the tile scale (the button bar)
    /// whose measured size is already final — only the centre needs mapping.
    func chromeViewRect(finalSize size: CGSize, centreOffsetInches off: CGPoint,
                        in t: Transform) -> CGRect {
        ArrangerGeometry.chromeViewRect(finalSize: size, centreOffsetInches: off,
                                        bounds: bounds, scale: t.scale)
    }

    /// The granny panel's rect — its centre-relative state through `chromeViewRect`.
    func panelViewRect() -> CGRect? {
        chromeViewRect(naturalSize: Self.panelNaturalSize, centreOffsetInches: state.solvePanelCenterOffsetInches)
    }

    /// The chrome pass: re-render bar/footer at this canvas's own tile scale, in normal
    /// or ghost dress. `active` is the canvas under the cursor (nil ⇒ this one is it).
    func renderChrome(active: Canvas?) {
        guard VirtualMouse.ghostChromeEnabled else { return }
        let inactive = active != nil && active !== self
        isGhost = inactive
        let myT = drawTransform(currentRects())
        if inactive, let myT, myT.scale > 0,
           let actT = active!.drawTransform(active!.currentRects()), actT.scale > 0 {
            // Ratio of the two minimap scales: a cursor beside a tile on the active
            // screen lands beside the matching tile here.
            ghostScale = myT.scale / actT.scale
            ghostActiveCenter = CGPoint(x: active!.bounds.midX, y: active!.bounds.midY)
        } else {
            ghostScale = 1
            ghostActiveCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        if let myT, myT.scale > 0 {
            let k = chromeTileScale(myT)
            updateBar(scale: k)
            layoutBar(in: myT)
            layoutFooter(scale: k)
        } else {
            updateBar()   // no transform yet — still reflect the fresh ghost state
        }
        solvePanel.setGhost(inactive)
    }

    /// Map a point from the active canvas's view coords onto this canvas (the ghost
    /// mapping the mouse and tooltip ride). Identity when active.
    func ghostPoint(_ p: CGPoint) -> CGPoint {
        ArrangerGeometry.ghostPoint(p, ghostScale: ghostScale, activeCenter: ghostActiveCenter,
                                    destCenter: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// Chrome size in proportion to this canvas's minimap tiles.
    func chromeTileScale(_ t: Transform) -> CGFloat {
        t.scale / ChromeMetrics.referenceMinimapScale
    }

    /// The current tile scale; 1 if the transform isn't ready. Inside a render pass
    /// prefer `chromeTileScale(_:)` with the pass's one transform.
    var chromeTileScale: CGFloat {
        guard let t = drawTransform(currentRects()), t.scale > 0 else { return 1 }
        return chromeTileScale(t)
    }

    /// Round to the nearest whole *device* pixel — a fractional origin smears content
    /// across pixel boundaries.
    func pixelSnap(_ v: CGFloat) -> CGFloat {
        ArrangerGeometry.pixelSnap(v, backingScale: window?.backingScaleFactor ?? 2)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { seamEmitters.clear(); seamGlow.clear() }
    }

    // Forwarding accessors so this view's methods read/write the shared state.
    var displays: [DisplaySnapshot] { get { state.displays } set { state.displays = newValue } }
    var selectedID: CGDirectDisplayID? { get { state.selectedID } set { state.selectedID = newValue } }
    var plane: [CGDirectDisplayID: CGRect] { state.plane }
    var pendingSize: [CGDirectDisplayID: CGSize] { get { state.pendingSize } set { state.pendingSize = newValue } }
    var pendingMode: (id: CGDirectDisplayID, mode: CGDisplayMode)? { get { state.pendingMode } set { state.pendingMode = newValue } }
    var activeV: (selfA: VAnchor, otherA: VAnchor, otherID: CGDirectDisplayID)? { get { state.activeV } set { state.activeV = newValue } }
    var activeH: (selfA: HAnchor, otherA: HAnchor, otherID: CGDirectDisplayID)? { get { state.activeH } set { state.activeH = newValue } }
    var extendedBuiltinModes: Bool { get { state.extendedBuiltinModes } set { state.extendedBuiltinModes = newValue } }

    /// The app-level command executor (see `DisplayCommanding`).
    var commander: (any DisplayCommanding)? { state.commander }

    var airplaySession: AirPlaySession? { state.airplaySession }

    // Mouse drag state (local to the canvas handling the gesture).
    var draggedID: CGDirectDisplayID?
    var dragStartMouse: CGPoint = .zero
    var dragStartPhys: CGPoint = .zero    // dragged tile's physical origin at grab
    var dragTransform: Transform?         // frozen during a drag (stable cursor mapping)
    var dragMoved = false

    /// This canvas's transform, frozen while a tile drag is live on ANY canvas
    /// (`state.draggingDisplayID`), so no screen's map recenters mid-drag.
    var sharedDragTransform: Transform?

    /// The transform to render with — frozen for the duration of a tile drag anywhere,
    /// live otherwise. All drawing and mouse-overlay placement goes through this.
    func drawTransform(_ rects: [CGDirectDisplayID: CGRect]) -> Transform? {
        guard state.draggingDisplayID != nil else {
            sharedDragTransform = nil
            return transform(rects)
        }
        if sharedDragTransform == nil { sharedDragTransform = dragTransform ?? transform(rects) }
        return sharedDragTransform
    }

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

    // Global (⌘⇧ ±) zoom run state: a continuous, *unclamped* scale on every display's
    // starting PPI. Tracking the unclamped level lets a maxed-out display stay pinned
    // while the level rises, then rejoin proportionally as it falls. Reset each run.
    var globalZoomLevel: Double = 1
    var globalZoomStartPPI: [CGDirectDisplayID: Double] = [:]

    var showAlignGhosts: Bool { get { state.showAlignGhosts } set { state.showAlignGhosts = newValue } }

    /// The display this canvas's window sits on. nil ⇒ center the main display.
    var centerID: CGDirectDisplayID?

    let outerPadding: CGFloat = 32
    let tileCornerRadius: CGFloat = 8

    /// Width of the right-hand column overlay (0 when it holds nothing).
    var mirrorColumnWidth: CGFloat {
        mirroredDisplays.isEmpty && airplaySession == nil ? 0 : 360
    }

    /// Cached native pixel aspect per display (fixed per panel; stale entries harmless).
    var nativeAspectCache: [CGDirectDisplayID: Double?] = [:]

    /// Cached desktop wallpaper per display, keyed by (id, image URL) so changes reload.
    var wallpaperCache: [CGDirectDisplayID: (url: URL, image: NSImage)?] = [:]

    override var acceptsFirstResponder: Bool { true }
    // Handle clicks even when this window isn't key (no activate-first click).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// True while the schematic host's DragGesture is live (its onChanged distinguishes
    /// began from moved with this).
    var mouseGestureActive = false

    /// Shift state fed by handleFlagsChanged — the nudge timer's fast-rate flag
    /// (kept here so Canvas+Input never reads NSEvent).
    var shiftHeld = false

    /// Commit any dangling keyboard manipulation when focus moves away.
    override func resignFirstResponder() -> Bool {
        if moveTimer != nil { stopMoveTimer(); commitPlane() }
        if alignPending { alignPending = false; commitPlane() }
        return super.resignFirstResponder()
    }

    /// Re-place the overlays once bounds settle (the layout() counterpart of refresh()).
    override func layout() {
        super.layout()
        bannerTop?.constant = state.uniformMenuBarInset + 12
        layoutLabelCards()   // overlays track a bounds change (draw never places them)
        layoutMirrorColumn()
        updateSeamEffects()
        onLayout?()          // re-render chrome now that bounds/frames are settled
    }

    /// Called by the state after a mutation: place the overlay subviews and feed the
    /// effect layers (`draw(_:)` never mutates the view tree or layers), then repaint.
    func refresh() {
        updateBar(); syncBanner()
        if let rect = panelViewRect(), solvePanel.frame != rect {
            solvePanel.frame = rect
        }
        updateSolvePanel()
        layoutLabelCards()
        layoutMirrorColumn()
        updateSeamEffects()
        repaintSchematic()
    }

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

    /// The plane↔view transform and the fit that chooses it live in `ArrangerGeometry`
    /// (framework-free, tested); this canvas supplies its own bounds/padding.
    typealias Transform = ArrangerGeometry.Transform

    func transform(_ rects: [CGDirectDisplayID: CGRect]) -> Transform? {
        ArrangerGeometry.fit(rects, in: bounds, padding: outerPadding)
    }
}

/// Chrome sizing constants and shared tints.
enum ChromeMetrics {
    /// The minimap scale at which chrome renders at natural size — the one knob for
    /// its absolute size (`chromeTileScale` = transform scale over this).
    static let referenceMinimapScale: CGFloat = 40

    /// The ghost tint as SwiftUI currency (the layer world takes its CGColor from
    /// `SeamPalette.colors[0]` directly).
    static var ghostPink: Color { Color(nsColor: SeamPalette.colors[0]) }
}
