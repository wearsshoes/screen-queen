import AppKit

/// The bottom button bar (feed · reset · undo · [resolution slider] · done) — its
/// construction (real Liquid Glass capsules on macOS 26, HUD fallback below), Dock-
/// aware placement, the tap/slider actions, and syncing to shared state. The bar's
/// views and cursor-state live as stored properties on Arranger.
extension Arranger {

    /// Idiomatic bottom button bar (Reset · Undo · Done) grouped in a rounded box,
    /// on every screen, sitting above the Dock.
    func setupButtonBar() {
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
        // dropped for the label; the images (rendered at the current bar scale, crisp) are
        // set by `refreshBarIcons`, called here and whenever state/scale change.
        // Copy lives in `Arranger.tooltipText(for:)` and shows via the fun bubble on every
        // canvas (VirtualMouse.swift) — no native `.toolTip` (it would pop on the hovered
        // screen only, doubling up). Accessibility labels ride the images' descriptions.
        for b in allButtons {
            b.imagePosition = .imageOnly
            b.title = ""
        }
        refreshBarIcons()

        // Resolution slider for the selected display: left = larger UI (lower res),
        // right = more space (higher res), matching macOS "Larger Text ↔ More Space".
        // A custom cell draws the bar so the ghost's pink track survives on non-key
        // canvases (where macOS would grey the stock track out).
        let sliderCell = ArrangerSliderCell()
        sliderCell.sliderType = .linear
        sliderCell.controlSize = .large
        resSlider.cell = sliderCell
        resSlider.minValue = 0
        resSlider.maxValue = 1
        resSlider.isContinuous = true
        resSlider.controlSize = .large
        resSlider.target = self
        resSlider.action = #selector(resSliderChanged)

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
                (button, prominent) -> HoverGlassView in
                // A square content box → the glass renders as a circle (radius = ½ side).
                let pad = NSView()
                pad.translatesAutoresizingMaskIntoConstraints = false
                button.translatesAutoresizingMaskIntoConstraints = false
                pad.addSubview(button)
                let w = pad.widthAnchor.constraint(equalToConstant: diameter)
                let h = pad.heightAnchor.constraint(equalToConstant: diameter)
                barMetrics.lengths += [(w, diameter), (h, diameter)]
                NSLayoutConstraint.activate([
                    w, h,
                    // The button *fills* the capsule (not just its icon-sized centre), so
                    // the whole bubble is the hover/click target — icon stays centred.
                    button.leadingAnchor.constraint(equalTo: pad.leadingAnchor),
                    button.trailingAnchor.constraint(equalTo: pad.trailingAnchor),
                    button.topAnchor.constraint(equalTo: pad.topAnchor),
                    button.bottomAnchor.constraint(equalTo: pad.bottomAnchor),
                ])

                // A lighter accent so the clear glass stays see-through on Done.
                let base = prominent
                    ? (NSColor.systemPink.blended(withFraction: 0.6, of: .white)
                        ?? .systemPink).withAlphaComponent(0.4)
                    : nil
                let g = HoverGlassView(baseTint: base)
                g.button = button         // hover only lights up while the button is enabled
                g.cornerRadius = diameter / 2   // full circle
                g.style = .clear          // high-transparency variant — see the backdrop through it
                g.contentView = pad
                barMetrics.corners.append((g, diameter / 2))
                return g
            }
            ghostGlassViews = glassy       // pinked in ghost mode via GhostTintable
            // The slider lives in its own wider glass pill, inserted between Undo and Done.
            let sliderPill = makeSliderPill(height: diameter)
            ghostGlassViews.append(sliderPill)
            var pieces: [NSView] = glassy
            pieces.insert(sliderPill, at: 3)   // feed, reset, undo, [slider], done

            let stack = NSStackView(views: pieces)
            stack.orientation = .horizontal
            stack.spacing = 22
            stack.translatesAutoresizingMaskIntoConstraints = false
            barMetrics.spacings.append((stack, 22))

            let group = NSGlassEffectContainerView()
            group.spacing = 14          // merge distance between neighboring glass shapes
            group.contentView = stack
            container = group
        } else {
            setSoftSliderWidth(preferred: 220)
            let stack = NSStackView(views: [feedButton, resetButton, undoButton, resSlider, doneButton])
            stack.orientation = .horizontal
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            barMetrics.spacings.append((stack, 12))
            buttonBar.material = .hudWindow
            buttonBar.blendingMode = .withinWindow
            buttonBar.state = .active
            buttonBar.wantsLayer = true
            buttonBar.layer?.cornerRadius = 22
            buttonBar.layer?.cornerCurve = .continuous
            buttonBar.layer?.borderWidth = 0.5
            buttonBar.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            buttonBar.addSubview(stack)
            let top = stack.topAnchor.constraint(equalTo: buttonBar.topAnchor, constant: 12)
            let bot = stack.bottomAnchor.constraint(equalTo: buttonBar.bottomAnchor, constant: -12)
            let lead = stack.leadingAnchor.constraint(equalTo: buttonBar.leadingAnchor, constant: 16)
            let trail = stack.trailingAnchor.constraint(equalTo: buttonBar.trailingAnchor, constant: -16)
            barMetrics.lengths += [(top, 12), (bot, -12), (lead, 16), (trail, -16)]
            NSLayoutConstraint.activate([top, bot, lead, trail])
            // No glass on this path — pink the HUD box's own chrome and the slider track.
            ghostTintTargets = [HUDBoxGhost(box: buttonBar), resSlider]
            container = buttonBar
        }
        // The container is frame-placed each render by `layoutBar` through the *same*
        // `chromeViewRect` the granny viewer uses — sized to its own fitting content, at
        // the shared centre-relative spot. Its internal stack still autolayout-sizes the
        // capsules (that's what gives `fittingSize`); we just position the whole box.
        container.translatesAutoresizingMaskIntoConstraints = true
        addSubview(container)
        // Cap the slider (the compressible member) so the bar never overflows a narrow
        // screen; the container's fitting size then follows.
        barMaxWidth = resSlider.widthAnchor.constraint(lessThanOrEqualToConstant: 100_000)
        barMaxWidth?.isActive = true
        barContainer = container   // frame-placed by layoutBar; tint is per element

        // The instruction line, right under the bar and centred on it. It's a sibling (not
        // a child of the glass container, which only composites its contentView). It's
        // positioned + font-sized in `layoutFooter` (called from renderChrome) to track the
        // bar at any zoom — scaling the *font*, not a rasterised bitmap, so it stays crisp.
        footerLabel.stringValue = Copy.footer
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.alignment = .center
        addSubview(footerLabel)
    }


    /// A glass pill hosting the resolution slider, flanked by "A" / "a" end glyphs —
    /// wider than the round button capsules, same height. In ghost mode the pill glass,
    /// the end glyphs, and the slider's track all wear pink (see `GhostGlassPill`).
    @available(macOS 26.0, *)
    private func makeSliderPill(height: CGFloat) -> GhostGlassPill {
        let big = NSTextField(labelWithString: "A")
        big.font = .boldSystemFont(ofSize: 20); big.textColor = .labelColor
        let small = NSTextField(labelWithString: "a")
        small.font = .systemFont(ofSize: 14); small.textColor = .labelColor
        barMetrics.glyphs += [(big, 20), (small, 14)]

        resSlider.translatesAutoresizingMaskIntoConstraints = false
        setSoftSliderWidth(preferred: 144)

        // Pin the scope toggle to a fixed width — the one/all symbols differ slightly in
        // intrinsic width, and without this the whole bar nudged when it swapped.
        scopeButton.translatesAutoresizingMaskIntoConstraints = false
        let scopeW = scopeButton.widthAnchor.constraint(equalToConstant: 24)
        scopeW.isActive = true
        barMetrics.lengths.append((scopeW, 24))

        let row = NSStackView(views: [big, resSlider, small, scopeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.setCustomSpacing(14, after: small)   // a little gap before the scope toggle
        barMetrics.spacings.append((row, 8))     // (the custom 14 after `small` stays fixed)

        let pad = NSView()
        pad.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        pad.addSubview(row)
        let padH = pad.heightAnchor.constraint(equalToConstant: height)
        let rowLead = row.leadingAnchor.constraint(equalTo: pad.leadingAnchor, constant: 20)
        let rowTrail = row.trailingAnchor.constraint(equalTo: pad.trailingAnchor, constant: -20)
        barMetrics.lengths += [(padH, height), (rowLead, 20), (rowTrail, -20)]
        NSLayoutConstraint.activate([
            padH, rowLead, rowTrail,
            row.centerYAnchor.constraint(equalTo: pad.centerYAnchor),
        ])

        let g = GhostGlassPill()
        g.cornerRadius = height / 2
        g.style = .clear
        g.contentView = pad
        barMetrics.corners.append((g, height / 2))
        // The pill drives its own contents pink in ghost mode: the slider's track and
        // the A/a end glyphs. (The scope button keeps its own accent — it's a toggle.)
        g.slider = resSlider
        g.glyphs = [big, small]
        return g
    }


    /// The slider is the bar's one compressible member: a preferred width the
    /// `barMaxWidth` cap can squeeze, with a firm-but-breakable floor so it never
    /// collapses to nothing before the cap gives up.
    ///
    /// The preferred width is high (not `.defaultLow`): the slider hugs its intrinsic
    /// size by default, so a *low*-priority width can't grow the bar past that — the
    /// slider just stays short. We also drop its horizontal hugging so it's happy to
    /// stretch. It's still below `barMaxWidth` (a `≤`), so an extreme-portrait screen can
    /// still squeeze it via the floor.
    private func setSoftSliderWidth(preferred: CGFloat) {
        resSlider.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let pref = resSlider.widthAnchor.constraint(equalToConstant: preferred)
        pref.priority = NSLayoutConstraint.Priority(750)
        let floor = resSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 60)
        floor.priority = NSLayoutConstraint.Priority(900)
        NSLayoutConstraint.activate([pref, floor])
        barMetrics.lengths += [(pref, preferred), (floor, 60)]
    }

    /// Place the bar and banner at the *uniform* anchor offsets (`ArrangerState`'s
    /// unified metrics): the same bottom/top insets and width cap on every canvas, so
    /// the chrome sits at identical anchor-space positions on every screen — never out
    /// of bounds on any of them, however extreme the aspect ratios.
    override func layout() {
        super.layout()
        bannerTop?.constant = state.uniformMenuBarInset + 12
        barMaxWidth?.constant = Self.barWidthCap(minScreenWidth: state.minScreenExtent.width)
        onLayout?()   // re-render chrome now that bounds/frames are settled
    }

    /// Place the button bar through `chromeViewRect` — the *same* positioning code as the
    /// granny viewer (centre-relative, tile-scaled). Its natural size is its own fitting
    /// content divided back out of the current scale (`chromeViewRect` re-applies the
    /// scale). Position-agnostic: `barCentreOffsetInches` just says where the centre sits.
    func layoutBar() {
        guard let container = barContainer else { return }
        container.layoutSubtreeIfNeeded()
        let k = chromeTileScale
        let fit = container.fittingSize
        let natural = CGSize(width: fit.width / max(k, 0.01), height: fit.height / max(k, 0.01))
        if let rect = chromeViewRect(naturalSize: natural, centreOffsetInches: barCentreOffsetInches) {
            container.frame = rect
        }
    }

    /// Where the bar's centre sits below the screen centre, in **plane inches** — the
    /// schematic's own unit, which `chromeViewRect` maps to view pixels via `transform.scale`
    /// (view-px per plane-inch). Map-relative like the granny viewer: drifts/rescales with
    /// the minimap zoom. (A plane-inch is a real desk-arrangement inch shown shrunk on the
    /// map, not a ruler-on-the-glass inch.)
    private var barCentreOffsetInches: CGPoint { CGPoint(x: 0, y: -10) }

    /// Lay the bar out at `scale` (its true final size) so every element renders vector-
    /// crisp, instead of layer-scaling a rasterised bar (which blurred). Mutates the
    /// captured constraints/fonts and re-renders the icons; the ghost transform is then a
    /// pure translation. No-op when the scale hasn't changed.
    func restyleBar(scale: CGFloat) {
        guard abs(scale - barMetrics.currentScale) > 0.001 else { return }
        barMetrics.currentScale = scale
        for (c, base) in barMetrics.lengths { c.constant = base * scale }
        for (stack, base) in barMetrics.spacings { stack.spacing = base * scale }
        if #available(macOS 26.0, *) {
            for (view, base) in barMetrics.corners { (view as? NSGlassEffectView)?.cornerRadius = base * scale }
        }
        let backing = window?.backingScaleFactor ?? 2
        for (glyph, base) in barMetrics.glyphs {
            let bold = glyph.font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            let pt = (base * scale).rounded()   // whole point hints crispest (see the footer)
            glyph.font = bold ? .boldSystemFont(ofSize: pt) : .systemFont(ofSize: pt)
            glyph.wantsLayer = true
            glyph.layer?.contentsScale = backing   // render the text at full display density
        }
        refreshBarIcons()
    }

    /// The base symbol point sizes (at scale 1); icons render at `× barMetrics.currentScale`.
    private var iconPt: CGFloat { 22 }
    private var scopePt: CGFloat { 15 }

    private func symbol(_ name: String, pt: CGFloat, weight: NSFont.Weight = .semibold) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: pt * barMetrics.currentScale, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    /// (Re)render every bar icon at the current scale — crisp, since the symbol is
    /// rasterised at its final point size rather than a small image being layer-scaled up.
    /// Feed and scope reflect state. Called on setup, on state change (`syncButtons`), and
    /// on scale change (`restyleBar`).
    func refreshBarIcons() {
        resetButton.image = symbol("arrow.counterclockwise", pt: iconPt)
        undoButton.image = symbol("arrow.uturn.backward", pt: iconPt)
        doneButton.image = symbol("checkmark", pt: iconPt)
        feedButton.image = symbol(state.feedEnabled ? "figure.run" : "figure.stand", pt: iconPt)
        scopeButton.image = symbol(state.sliderScope == .all ? "rectangle.stack" : "rectangle", pt: scopePt)
        feedButtonSymbol = state.feedEnabled ? "figure.run" : "figure.stand"
    }

    @objc private func resetTapped() { state.onReset?() }
    @objc private func undoTapped() { state.undo() }
    @objc private func doneTapped() { onDismiss?() }
    @objc private func feedTapped() { state.onToggleFeed?(!state.feedEnabled) }
    @objc private func scopeTapped() {
        state.sliderScope = state.sliderScope == .one ? .all : .one
        state.notify()   // refresh every canvas so the icon/tooltip update everywhere
    }


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
            state.onSliderDragChanged?(true)    // drive the ghost aids while held
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
            state.onSliderDragChanged?(false)   // stop the drag-driven ghost updates
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
    func syncButtons() {
        // Undo and Reset are both no-ops until something's changed — `canUndo` is true
        // exactly when there's an edit (or pending revert) to step back or reset. So both
        // start disabled on open and light up on the first change.
        undoButton.isEnabled = state.canUndo
        resetButton.isEnabled = state.canUndo

        // Feed (run/stand) + scope (one/all) icons reflect state. Re-render only when the
        // feed symbol actually flips — `syncButtons` runs on every notify, and rebuilding
        // the images each time is churn. `refreshBarIcons` renders all icons at the current
        // bar scale (crisp). The scope symbol also flips, so guard on either changing.
        let feedSymbol = state.feedEnabled ? "figure.run" : "figure.stand"
        if feedSymbol != feedButtonSymbol {
            refreshBarIcons()
        } else {
            // Scope can flip without the feed changing — refresh just its icon.
            scopeButton.image = symbol(state.sliderScope == .all ? "rectangle.stack" : "rectangle", pt: scopePt)
        }

        applyStateIconGhostTint()   // feed + scope icons: pink on a ghost canvas, else black

        let selected = selectedID.flatMap { id in displays.first(where: { $0.id == id }) }
        sliderModes = selected.map { sortedModes(for: $0) } ?? []
        let usable = sliderModes.count > 1
        resSlider.isEnabled = usable
        if usable, let d = selected {
            let pending = state.pendingMode(for: d.id)
            if let pending, isGhost,
               let idx = sliderModes.firstIndex(where: { ModeCatalog.sameMode(pending, $0.cgMode) }) {
                // A ghost canvas isn't the one being dragged, so mirror the live preview —
                // the drag consumes the cursor on the active screen, so this is the only
                // place the resolution change shows up over here.
                resSlider.doubleValue = Double(idx) / Double(sliderModes.count - 1)
            } else if pending == nil {
                // Not mid-drag: re-sync from the committed mode. (On the *active* canvas we
                // never fight the live drag — the slider drives itself there.)
                let idx = currentModeIndex(for: d, in: sliderModes) ?? (sliderModes.count - 1) / 2
                resSlider.doubleValue = Double(idx) / Double(sliderModes.count - 1)
            }
        }
    }

    /// Tint the icons/slider whose look is driven by *state* (feed, scope, slider track)
    /// for the current ghost mode: pink on a ghost canvas, black/normal on the active one.
    ///
    /// Called both from `syncButtons` and from `renderChrome`. The catch: `syncButtons`
    /// runs *before* `renderChrome` sets `isGhost`, so right after an active-screen change
    /// it reads a stale value and would show pink/black inverted for a beat — `renderChrome`
    /// re-runs this with the fresh `isGhost` to settle it.
    func applyStateIconGhostTint() {
        let tint: NSColor = isGhost ? VirtualMouse.pink : .labelColor
        feedButton.contentTintColor = tint
        scopeButton.contentTintColor = tint
        (resSlider.cell as? ArrangerSliderCell)?.barTint = isGhost ? VirtualMouse.pink : nil
        resSlider.needsDisplay = true
    }
}
