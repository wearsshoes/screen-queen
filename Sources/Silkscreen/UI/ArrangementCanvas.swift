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
    private let feedButton = NSButton(title: "", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    /// Resolution slider (A ↔ a) for the selected display, in the bottom cluster.
    private let resSlider = NSSlider()
    /// One/All scope toggle for the slider (single rectangle vs. overlapping rectangles).
    private let scopeButton = NSButton(title: "", target: nil, action: nil)
    private let buttonBar = NSVisualEffectView()

    /// The selected display's sorted modes, cached while the slider drives them so a
    /// live preview doesn't recompute per tick. Rebuilt in `syncButtons`.
    private var sliderModes: [DisplayMode] = []

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

    /// Idiomatic bottom button bar (Reset · Undo · Done) grouped in a rounded box,
    /// on every screen, sitting above the Dock.
    private func setupButtonBar() {
        resetButton.keyEquivalent = "\u{8}"; resetButton.keyEquivalentModifierMask = .command  // ⌘Delete
        resetButton.target = self; resetButton.action = #selector(resetTapped)
        undoButton.keyEquivalent = "z"; undoButton.keyEquivalentModifierMask = .command
        undoButton.target = self; undoButton.action = #selector(undoTapped)
        doneButton.target = self; doneButton.action = #selector(doneTapped)
        doneButton.keyEquivalent = "\r"   // primary action → renders blue (default button)
        feedButton.target = self; feedButton.action = #selector(feedTapped)
        let allButtons = [feedButton, resetButton, undoButton, doneButton]
        for b in allButtons {
            b.bezelStyle = .push
            b.controlSize = .large
        }
        // Icon-only round glass buttons (like the Spotlight icon pills). Titles are
        // dropped for the label; tooltips keep them identifiable. The feed icon is set in
        // syncButtons (it flips between play/stop with the toggle state).
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        resetButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset")
        undoButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo")
        doneButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Done")
        resetButton.toolTip = "Reset"; undoButton.toolTip = "Undo"; doneButton.toolTip = "Done"
        for b in allButtons {
            b.image = b.image?.withSymbolConfiguration(iconConfig)
            b.imagePosition = .imageOnly
            b.title = ""
        }
        resetButton.image = resetButton.image?.rotatedCCW(degrees: 120, offset: CGSize(width: -1, height: 0))

        // Resolution slider for the selected display: left = larger UI (lower res),
        // right = more space (higher res), matching macOS "Larger Text ↔ More Space".
        resSlider.minValue = 0
        resSlider.maxValue = 1
        resSlider.isContinuous = true
        resSlider.controlSize = .large
        resSlider.target = self
        resSlider.action = #selector(resSliderChanged)
        resSlider.toolTip = "Resolution"

        // One/All scope toggle (icon set in syncButtons to reflect the current scope).
        scopeButton.isBordered = false
        scopeButton.imagePosition = .imageOnly
        scopeButton.target = self
        scopeButton.action = #selector(scopeTapped)

        // Each button is its own glass capsule (like the Spotlight icon pills), grouped
        // in a container so nearby glass samples the backdrop consistently and merges
        // fluidly. On macOS 26+ (Tahoe) this is real Liquid Glass; older systems keep
        // the ordinary buttons in a plain stack.
        let container: NSView
        if #available(macOS 26.0, *) {
            // Chromeless buttons so the glass capsule *is* the surface; the label/icon
            // still draws (border off ≠ content off).
            for b in [feedButton, resetButton, undoButton, doneButton] {
                b.isBordered = false
                b.contentTintColor = .labelColor
            }

            // Wrap each button in a padding container, and set THAT as the glass view's
            // contentView. (Adding a control directly to the glass view renders it blank
            // — the glass only composites its `contentView`.)
            let diameter: CGFloat = 56
            let glassy = zip([feedButton, resetButton, undoButton, doneButton], [false, false, false, true]).map {
                (button, prominent) -> NSGlassEffectView in
                // A square content box → the glass renders as a circle (radius = ½ side).
                let pad = NSView()
                pad.translatesAutoresizingMaskIntoConstraints = false
                button.translatesAutoresizingMaskIntoConstraints = false
                pad.addSubview(button)
                NSLayoutConstraint.activate([
                    pad.widthAnchor.constraint(equalToConstant: diameter),
                    pad.heightAnchor.constraint(equalToConstant: diameter),
                    button.centerXAnchor.constraint(equalTo: pad.centerXAnchor),
                    button.centerYAnchor.constraint(equalTo: pad.centerYAnchor),
                ])

                // A lighter accent so the clear glass stays see-through on Done.
                let base = prominent
                    ? (NSColor.controlAccentColor.blended(withFraction: 0.72, of: .white)
                        ?? .controlAccentColor).withAlphaComponent(0.35)
                    : nil
                let g = HoverGlassView(baseTint: base)
                g.button = button         // hover only lights up while the button is enabled
                g.cornerRadius = diameter / 2   // full circle
                g.style = .clear          // high-transparency variant — see the backdrop through it
                g.contentView = pad
                return g
            }
            // The slider lives in its own wider glass pill, inserted between Undo and Done.
            let sliderPill = makeSliderPill(height: diameter)
            var pieces: [NSView] = glassy
            pieces.insert(sliderPill, at: 3)   // feed, reset, undo, [slider], done

            let stack = NSStackView(views: pieces)
            stack.orientation = .horizontal
            stack.spacing = 22
            stack.translatesAutoresizingMaskIntoConstraints = false

            let group = NSGlassEffectContainerView()
            group.spacing = 14          // merge distance between neighboring glass shapes
            group.contentView = stack
            container = group
        } else {
            resSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
            let stack = NSStackView(views: [feedButton, resetButton, undoButton, resSlider, doneButton])
            stack.orientation = .horizontal
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            buttonBar.material = .hudWindow
            buttonBar.blendingMode = .withinWindow
            buttonBar.state = .active
            buttonBar.wantsLayer = true
            buttonBar.layer?.cornerRadius = 22
            buttonBar.layer?.cornerCurve = .continuous
            buttonBar.layer?.borderWidth = 0.5
            buttonBar.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            buttonBar.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: buttonBar.topAnchor, constant: 12),
                stack.bottomAnchor.constraint(equalTo: buttonBar.bottomAnchor, constant: -12),
                stack.leadingAnchor.constraint(equalTo: buttonBar.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: buttonBar.trailingAnchor, constant: -16),
            ])
            container = buttonBar
        }
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        container.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        buttonBarBottom = container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -baseBottomMargin)
        buttonBarBottom?.isActive = true
    }

    /// Base clearance above the screen bottom (before adding the Dock height): enough to
    /// clear a bottom-edge alignment arrow, but no more — the Dock inset is added on top.
    private let baseBottomMargin: CGFloat = 40

    /// A glass pill hosting the resolution slider, flanked by "A" / "a" end glyphs —
    /// wider than the round button capsules, same height.
    @available(macOS 26.0, *)
    private func makeSliderPill(height: CGFloat) -> NSGlassEffectView {
        let big = NSTextField(labelWithString: "A")
        big.font = .boldSystemFont(ofSize: 20); big.textColor = .labelColor
        let small = NSTextField(labelWithString: "a")
        small.font = .systemFont(ofSize: 14); small.textColor = .labelColor

        resSlider.translatesAutoresizingMaskIntoConstraints = false
        resSlider.widthAnchor.constraint(equalToConstant: 172).isActive = true

        let row = NSStackView(views: [big, resSlider, small, scopeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.setCustomSpacing(14, after: small)   // a little gap before the scope toggle

        let pad = NSView()
        pad.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        pad.addSubview(row)
        NSLayoutConstraint.activate([
            pad.heightAnchor.constraint(equalToConstant: height),
            row.leadingAnchor.constraint(equalTo: pad.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: pad.trailingAnchor, constant: -20),
            row.centerYAnchor.constraint(equalTo: pad.centerYAnchor),
        ])

        let g = NSGlassEffectView()
        g.cornerRadius = height / 2
        g.style = .clear
        g.contentView = pad
        return g
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
            buttonBarBottom?.constant = -baseBottomMargin - dockInset
        }
    }

    @objc private func resetTapped() { state.onReset?() }
    @objc private func undoTapped() { state.undo() }
    @objc private func doneTapped() { onDismiss?() }
    @objc private func feedTapped() { state.onToggleFeed?(!state.feedEnabled) }
    @objc private func scopeTapped() {
        state.sliderScope = state.sliderScope == .one ? .all : .one
        state.notify()   // refresh every canvas so the icon/tooltip update everywhere
    }

    /// Index of the selected display's mode at the moment a slider drag began, so `.all`
    /// scope can apply the same *step delta* to every display.
    private var sliderDragStartIndex: Int?

    /// Live-preview resolution as the slider moves — the selected display in `.one` scope,
    /// or every display by the same step delta in `.all` scope. Commit on mouse-up.
    @objc private func resSliderChanged() {
        guard let id = selectedID, sliderModes.count > 1 else { return }
        let n = sliderModes.count
        let idx = max(0, min(n - 1, Int((Double(n - 1) * resSlider.doubleValue).rounded())))
        resSlider.doubleValue = Double(idx) / Double(n - 1)   // snap knob to the detent

        // Remember where the drag started (first change since a fresh mouse-down).
        let event = NSApp.currentEvent?.type
        if sliderDragStartIndex == nil {
            sliderDragStartIndex = currentModeIndex(for: displays.first { $0.id == id }!, in: sliderModes)
        }

        switch state.sliderScope {
        case .one:
            previewMode(sliderModes[idx], on: id)
        case .all:
            let delta = idx - (sliderDragStartIndex ?? idx)
            previewProportional(stepDelta: delta)
        }

        if event == .leftMouseUp {
            commitPendingResolution()
            sliderDragStartIndex = nil
        }
    }

    /// Preview every display shifted by `stepDelta` detents from its *current* mode
    /// (clamped to each display's own range), for `.all` scope.
    private func previewProportional(stepDelta: Int) {
        state.pendingModes.removeAll(); pendingSize.removeAll()
        for d in displays where !d.isMirrored {
            let modes = sortedModes(for: d)
            guard modes.count > 1, let base = currentModeIndex(for: d, in: modes) else { continue }
            let target = max(0, min(modes.count - 1, base + stepDelta))
            previewMode(modes[target], on: d.id, replacing: false)
        }
        needsDisplay = true
        emitPreview()
    }

    /// Reflect undo availability and sync the resolution slider to the selected display.
    private func syncButtons() {
        undoButton.isEnabled = state.canUndo

        // Feed toggle: a running stick figure when live (on), standing when off.
        let feedCfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        let feedSymbol = state.feedEnabled ? "figure.run" : "figure.stand"
        feedButton.image = NSImage(systemSymbolName: feedSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(feedCfg)
        feedButton.contentTintColor = .labelColor
        feedButton.toolTip = state.feedEnabled ? "Stop live preview" : "Show live preview"

        // One/All scope toggle: single rectangle = one display, overlapping = all.
        let scopeCfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let scopeSymbol = state.sliderScope == .all ? "rectangle.on.rectangle" : "rectangle"
        scopeButton.image = NSImage(systemSymbolName: scopeSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(scopeCfg)
        scopeButton.contentTintColor = state.sliderScope == .all ? .controlAccentColor : .secondaryLabelColor
        scopeButton.toolTip = state.sliderScope == .all
            ? "Zoom all displays proportionally" : "Zoom the selected display only"

        let selected = selectedID.flatMap { id in displays.first(where: { $0.id == id }) }
        sliderModes = selected.map { sortedModes(for: $0) } ?? []
        let usable = sliderModes.count > 1
        resSlider.isEnabled = usable
        if usable, let d = selected {
            // Don't fight a live drag/preview: only re-sync from the committed mode.
            if pendingMode?.id != d.id {
                let idx = currentModeIndex(for: d, in: sliderModes) ?? (sliderModes.count - 1) / 2
                resSlider.doubleValue = Double(idx) / Double(sliderModes.count - 1)
            }
        }
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
