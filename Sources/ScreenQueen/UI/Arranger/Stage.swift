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
final class Stage: NSView {

    /// One coordinate system everywhere: the plane is y-down (`CGDisplayBounds`), the
    /// SwiftUI Canvas and gestures are y-down, so the view is too — no flip gates.
    override var isFlipped: Bool { true }

    /// Shared editing model — one instance across every per-screen stage.
    let model: ArrangerModel

    /// The bottom button bar — a SwiftUI island (see ButtonBarView), hosted per
    /// stage and rebuilt from model in `updateBar`.
    var barHost: NSHostingView<ButtonBarView>?
    /// The chromeTileScale the bar last rendered at (set by renderChrome's pass).
    var barScale: CGFloat = 1
    /// The bar control under the real cursor, reported by the bar island's `.onHover`
    /// (SwiftUI owns the hit-testing) — the active stage's value drives every
    /// stage's ghost tooltip.
    var hoveredBarControl: BarControl?

    /// Clearance above the screen bottom before the Dock inset is added.
    let baseBottomMargin: CGFloat = 40

    /// The cap rule: narrowest screen minus breathing room, floored so pathological
    /// screens degrade to a slightly-overflowing bar instead of a constraint brawl.
    static func barWidthCap(minScreenWidth: CGFloat) -> CGFloat {
        max(320, minScreenWidth - 64)
    }

    /// The instruction line under the bar (see `FooterView`), scaled/positioned with it.
    var footerHost: FooterHost?

    /// Ghost-mapping state for `ghostPoint` (the ghost mouse + tooltip): this stage's
    /// minimap scale ÷ the active stage's, and the active stage's centre. Recomputed
    /// in `renderChrome` on active-screen change.
    var ghostArrow: GhostCursorLayer?
    var ghostScale: CGFloat = 1
    var ghostActiveCenter: CGPoint = .zero
    /// True while this stage shows the pink ghost chrome (cursor is on another screen).
    var isGhost = false

    /// This stage's minimap — the tiles/seams/markers/cards/beacon subjects and
    /// their storage (see Minimap.swift).
    private(set) lazy var minimap = Minimap(stage: self)

    /// The right-hand mirror/AirPlay column (see `MirrorColumn`); created on demand.
    var mirrorColumn: MirrorColumnHost?

    /// Fired at the end of `layout()`, once `bounds` is final, so the chrome re-renders
    /// with the settled size.
    var onLayout: (() -> Void)?

    /// The fun tooltip bubble — shown on *every* stage at the mirrored cursor position.
    var tooltipBubble: TooltipHost?

    /// The top-of-screen countdown banner — built on demand in CountdownBanner.swift.
    /// The first SwiftUI island: an NSHostingView subview on the stage.
    var banner: NSHostingView<CountdownBannerView>?
    /// The banner's top constraint, re-tuned in `layout()` to clear the menu bar.
    var bannerTop: NSLayoutConstraint?

    /// The schematic renderer — a SwiftUI Canvas island (StageCanvasView, below),
    /// below every effect layer/subview (added first, default z). Click-through; this
    /// view keeps all input handling.
    private(set) var canvasHost: StageCanvasHost!
    private var canvasGeneration = 0

    /// Repaint the schematic — the Canvas-era `needsDisplay = true`.
    func repaintCanvas() {
        canvasGeneration += 1
        canvasHost.rootView = StageCanvasView(stage: self, generation: canvasGeneration)
    }

    init(model: ArrangerModel, frame: NSRect) {
        self.model = model
        super.init(frame: frame)
        let host = StageCanvasHost(rootView: StageCanvasView(stage: self, generation: 0))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)   // first subview — everything else composites above
        canvasHost = host
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
        let p = SolvePanelHost(rootView: SolvePanelView(model: model))
        p.frame = NSRect(origin: .zero, size: NSSize(width: 240, height: 166))
        p.wantsLayer = true
        p.layer?.zPosition = 3
        // A drag stores the panel's centre as an inch offset from the screen centre —
        // its own state (moving a tile never moves it), scaling with the minimap.
        p.onMoved = { [weak self] origin in
            guard let self, let t = self.drawTransform(self.currentRects()), t.scale > 0 else { return }
            let centre = CGPoint(x: origin.x + p.frame.width / 2, y: origin.y + p.frame.height / 2)
            self.model.solvePanelCenterOffsetInches = CGPoint(
                x: (centre.x - self.bounds.midX) / t.scale,
                y: (centre.y - self.bounds.midY) / t.scale)
            self.model.notify()
        }
        addSubview(p)
        return p
    }()

    /// The granny panel's natural size in points, at `chromeTileScale == 1`.
    static let panelNaturalSize = CGSize(width: 208, height: 144)

    /// Place a *map-relative* chrome element: size = `naturalSize × chromeTileScale`
    /// (rides the tiles), centre = `bounds.mid + offset × transform.scale`. The offset is
    /// in **plane inches** (the schematic's physical unit, shown shrunk on the map) — NOT
    /// real on-glass inches. Same map-relative spot on every stage.
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
        chromeViewRect(naturalSize: Self.panelNaturalSize, centreOffsetInches: model.solvePanelCenterOffsetInches)
    }

    /// The chrome pass: re-render bar/footer at this stage's own tile scale, in normal
    /// or ghost dress. `active` is the stage under the cursor (nil ⇒ this one is it).
    /// The scale/placement half always runs; only the pink dressing consults the flag.
    func renderChrome(active: Stage?) {
        let inactive = active != nil && active !== self
        isGhost = Prefs.ghostChrome && inactive
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
        solvePanel.setGhost(isGhost)
    }

    /// Map a point from the active stage's view coords onto this stage (the ghost
    /// mapping the mouse and tooltip ride). Identity when active.
    func ghostPoint(_ p: CGPoint) -> CGPoint {
        ArrangerGeometry.ghostPoint(p, ghostScale: ghostScale, activeCenter: ghostActiveCenter,
                                    destCenter: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// Chrome size in proportion to this stage's minimap tiles.
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

    // Forwarding accessors so this view's methods read/write the shared model.
    var displays: [DisplaySnapshot] { get { model.displays } set { model.displays = newValue } }
    var selectedID: CGDirectDisplayID? { get { model.selectedID } set { model.selectedID = newValue } }
    var plane: [CGDirectDisplayID: CGRect] { model.plane }
    var activeV: AnchorMarker? { get { model.activeV } set { model.activeV = newValue } }
    var activeH: AnchorMarker? { get { model.activeH } set { model.activeH = newValue } }

    /// The app-level command executor (see `DisplayCommanding`).
    var commander: (any DisplayCommanding)? { model.commander }

    // Mouse drag state (local to the stage handling the gesture).
    var draggedID: CGDirectDisplayID?
    var dragStartMouse: CGPoint = .zero
    var dragStartPhys: CGPoint = .zero    // dragged tile's physical origin at grab
    var dragTransform: Transform?         // frozen during a drag (stable cursor mapping)
    var dragMoved = false

    /// This stage's transform, frozen while a tile drag is live on ANY stage
    /// (`model.draggingDisplayID`), so no screen's map recenters mid-drag.
    var sharedDragTransform: Transform?

    /// The transform to render with — frozen for the duration of a tile drag anywhere,
    /// live otherwise. All drawing and mouse-overlay placement goes through this.
    func drawTransform(_ rects: [CGDirectDisplayID: CGRect]) -> Transform? {
        guard model.draggingDisplayID != nil else {
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

    /// The display this stage's window sits on. nil ⇒ center the main display.
    var centerID: CGDirectDisplayID?

    let outerPadding: CGFloat = 32

    override var acceptsFirstResponder: Bool { true }
    // Handle clicks even when this window isn't key (no activate-first click).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// True while the schematic host's DragGesture is live (its onChanged distinguishes
    /// began from moved with this).
    var mouseGestureActive = false

    /// Shift state fed by handleFlagsChanged — the nudge timer's fast-rate flag
    /// (kept here so Stage+Input never reads NSEvent).
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
        bannerTop?.constant = model.uniformMenuBarInset + 12
        minimap.layoutLabelCards()   // overlays track a bounds change (draw never places them)
        layoutMirrorColumn()
        updateSeamEffects()
        onLayout?()          // re-render chrome now that bounds/frames are settled
    }

    /// Called by the model after a mutation: place the overlay subviews and feed the
    /// effect layers (`draw(_:)` never mutates the view tree or layers), then repaint.
    /// (The bar is NOT rebuilt here — every `changed` broadcast is followed by the
    /// deferred chrome pass, the one bar path, so each mutation renders it once.)
    func refresh() {
        syncBanner()
        if let rect = panelViewRect(), solvePanel.frame != rect {
            solvePanel.frame = rect
        }
        solvePanel.isHidden = model.planeDisplays.count < 2   // nothing to say about a solo girl
        minimap.layoutLabelCards()
        layoutMirrorColumn()
        updateSeamEffects()
        repaintCanvas()
    }

    func currentRects() -> [CGDirectDisplayID: CGRect] { plane }

    /// Commit the plane, then broadcast so every stage redraws.
    func commitPlane() { model.commit() }

    /// Broadcast a plane change so every per-screen stage redraws.
    func emitPreview() { model.notify() }

    // MARK: - View transform (fit the physical plane into the window)

    /// The plane↔view transform and the fit that chooses it live in `ArrangerGeometry`
    /// (framework-free, tested); this stage supplies its own bounds/padding.
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

    /// The ghost tint as SwiftUI currency (the layer world takes `SeamPalette.pinkCG`).
    static var ghostPink: Color { Color(nsColor: SeamPalette.pink) }
}

/// The schematic, hosted in a SwiftUI `Canvas`. The render pass
/// (`Stage.render(in:size:)`) draws natively into the GraphicsContext.
///
/// Mouse input lives here too (phase 2 of the input port): one DragGesture drives the
/// stage's began/moved/ended handlers — a plain click is a zero-distance drag, same as
/// mouseDown/mouseUp. Gesture points pass straight through: the view is flipped, so
/// gesture, Stage, and view space are all the same y-down coordinates.
struct StageCanvasView: View {
    weak var stage: Stage?
    /// Bumped by `repaintCanvas()` for the *stage-local* render inputs (drag points,
    /// frozen transforms) that Observation can't see.
    var generation: Int

    var body: some View {
        // Observation: the render pass's model reads, touched in body — reads inside
        // the Canvas closure aren't tracked. Any model mutation repaints every canvas,
        // broadcast or no; the stage-local drag state rides `generation`.
        if let m = stage?.model {
            _ = (m.plane, m.displays, m.selectedID, m.pendingModes, m.showAlignGhosts,
                 m.draggingDisplayID, m.lockedPointOrigins, m.feedEnabled,
                 m.activeV, m.activeH, m.pendingMainID)
        }
        return Canvas { ctx, size in
            _ = generation
            stage?.render(in: ctx, size: size)
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in
                guard let stage else { return }
                if stage.mouseGestureActive { stage.mouseMoved(to: g.location) }
                else { stage.mouseBegan(at: g.location, option: NSEvent.modifierFlags.contains(.option)) }
            }
            .onEnded { g in
                stage?.mouseEnded(at: g.location)
            })
    }
}

/// The schematic's hosting view. Left-button input goes to the SwiftUI gesture above;
/// right-click forwards to the stage's context-menu builder; first clicks land even
/// when the overlay window isn't key.
final class StageCanvasHost: NSHostingView<StageCanvasView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? {
        rootView.stage?.menu(for: event)
    }
    /// Key this screen's arranger on click, before the gesture fires — the AppKit
    /// half of the click that the framework-free mouseBegan no longer does.
    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        if let stage = rootView.stage { window?.makeFirstResponder(stage) }
        super.mouseDown(with: event)
    }
}

// MARK: - The render pass

/// `render(in:size:)` orchestrates the schematic in paint order. The subjects
/// live in their own files — the minimap (Minimap/Stage+Tiles, +TileSeams,
/// +TileMarkers) and the on-glass halves (Chrome/Glass/EdgeSeams, EdgeMarkers).
extension Stage {

    func render(in ctx: GraphicsContext, size: CGSize) {
        // The backdrop wash. If this screen's own tile is being dragged (from any
        // stage), brighten it — a real-world "you're dragging me" cue.
        let beingDragged = centerID != nil && model.draggingDisplayID == centerID
        let wash: Color = beingDragged
            ? Color(nsColor: NSColor.systemPink.blended(withFraction: 0.2, of: .black) ?? .systemPink).opacity(0.75)
            : Color.black.opacity(0.55)
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(wash))

        let rects = currentRects()
        guard let t = drawTransform(rects) else {
            ctx.draw(Text(Copy.emptyState).font(.system(size: 14))
                .foregroundStyle(.secondary),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let bars = model.currentBars()
        let seamColor = model.seamColors(bars)   // color per seam; both its bars share it
        if model.showAlignGhosts { minimap.drawAlignGhosts(ctx, t: t) }   // under the tiles
        // Selection halo before the tiles, so it reads under the lifted tile.
        if let sel = selectedID, let r = rects[sel] { minimap.drawSelectedShadow(ctx, t.viewRect(r)) }
        for d in displays where rects[d.id] != nil { minimap.drawTile(ctx, for: d, in: t.viewRect(rects[d.id]!)) }
        // Predicted Dock strip. With the live feed on the tiles already show the real
        // Dock, so only surface it when informative (Dock would move / mid menu-bar drag).
        if let dockID = model.predictedDockDisplay(), let r = rects[dockID] {
            let dockWouldMove = dockID != model.currentDockDisplay()
            let showDock = !model.feedEnabled || dockWouldMove || draggingMenuBar != nil
            if showDock {
                minimap.drawDockIndicator(ctx, in: t.viewRect(r), edge: DockPredictor.edge())
            }
        }
        // Seam glows, painted from the same edge sets `updateSeamEffects` feeds to the
        // emitter/glow layers (on the refresh path — draw registers nothing).
        for e in minimap.miniBarEdges(bars, t: t, seamColor: seamColor) { drawBehindGlow(ctx, e) }
        let markers = minimap.activeMarkers(rects)
        for d in displays where rects[d.id] != nil { minimap.drawAnchors(ctx, for: d, in: t.viewRect(rects[d.id]!), active: markers[d.id]) }
        for e in edgeBarEdges(bars, seamColor: seamColor) { drawBehindGlow(ctx, e) }
        drawScreenMarkers(ctx, markers)           // alignment notches/arrows at this screen's real edges
        if let p = draggingMenuBar {
            // The strip follows the cursor; highlight the tile it would land on.
            if let over = display(at: p), !over.isMain, let r = rects[over.id] {
                let vr = t.viewRect(r).insetBy(dx: 1.5, dy: 1.5)
                ctx.fill(Path(roundedRect: vr, cornerRadius: minimap.tileCornerRadius),
                         with: .color(.white.opacity(0.25)))
            }
            minimap.drawMenuBar(ctx, in: NSRect(x: p.x - 40, y: p.y - 8, width: 80, height: 16))
        }
        // Option-mirror drag: highlight the tile the dragged display would mirror onto.
        if let p = mirrorDragPoint, let over = display(at: p), over.id != draggedID, let r = rects[over.id] {
            let vr = t.viewRect(r).insetBy(dx: 1.5, dy: 1.5)
            let pink = Color.pink
            let path = Path(roundedRect: vr, cornerRadius: minimap.tileCornerRadius)
            ctx.fill(path, with: .color(pink.opacity(0.35)))
            ctx.stroke(path, with: .color(pink), lineWidth: 2)
            ctx.draw(Text(Copy.mirrorDropHint).font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white),
                     at: CGPoint(x: vr.midX, y: vr.midY))
        }
    }
}
