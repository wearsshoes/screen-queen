import AppKit

/// The bottom button bar (feed · reset · undo · [resolution slider] · done): real Liquid
/// Glass capsules on macOS 26, HUD fallback below, plus the tap/slider actions and state
/// syncing. The bar's views live as stored properties on Arranger.
extension Arranger {

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
        // Icon-only buttons; copy shows via the fun bubble on every canvas, so no native
        // `.toolTip`. Accessibility labels ride the images' descriptions.
        for b in allButtons {
            b.imagePosition = .imageOnly
            b.title = ""
        }
        refreshBarIcons()

        // Resolution slider: left = larger UI, right = more space (matching macOS).
        // The custom cell keeps the ghost's pink track on non-key windows.
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

        scopeButton.isBordered = false
        scopeButton.imagePosition = .imageOnly
        scopeButton.target = self
        scopeButton.action = #selector(scopeTapped)

        // Each button is its own glass capsule, grouped so neighboring glass merges.
        let container: NSView
        if #available(macOS 26.0, *) {
            // Chromeless buttons: the glass capsule *is* the surface (border off ≠ content off).
            for b in [feedButton, resetButton, undoButton, doneButton] {
                b.isBordered = false
                b.contentTintColor = .labelColor
            }

            // Wrap each button in a padding container and set THAT as the glass view's
            // contentView — a control added directly to the glass renders blank.
            let diameter: CGFloat = 56
            let glassy = zip([feedButton, resetButton, undoButton, doneButton], [false, false, false, true]).map {
                (button, prominent) -> HoverGlassView in
                // A square content box → the glass renders as a circle.
                let pad = NSView()
                pad.translatesAutoresizingMaskIntoConstraints = false
                button.translatesAutoresizingMaskIntoConstraints = false
                pad.addSubview(button)
                let w = pad.widthAnchor.constraint(equalToConstant: diameter)
                let h = pad.heightAnchor.constraint(equalToConstant: diameter)
                barMetrics.lengths += [(w, diameter), (h, diameter)]
                NSLayoutConstraint.activate([
                    w, h,
                    // The button fills the capsule so the whole bubble is the click target.
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
                g.button = button         // hover only lights up while enabled
                g.cornerRadius = diameter / 2
                g.style = .clear
                g.contentView = pad
                barMetrics.corners.append((g, diameter / 2))
                return g
            }
            ghostGlassViews = glassy
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
        // Frame-placed each render by `layoutBar`; the internal stack still autolayouts
        // (that's what gives `fittingSize`).
        container.translatesAutoresizingMaskIntoConstraints = true
        addSubview(container)
        // Cap the slider (the compressible member) so the bar never overflows a narrow screen.
        barMaxWidth = resSlider.widthAnchor.constraint(lessThanOrEqualToConstant: 100_000)
        barMaxWidth?.isActive = true
        barContainer = container

        // The instruction line under the bar — a sibling (the glass container only
        // composites its contentView). Positioned + font-sized in `layoutFooter`.
        footerLabel.stringValue = Copy.footer
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.alignment = .center
        addSubview(footerLabel)
    }


    /// A glass pill hosting the resolution slider, flanked by "A" / "a" end glyphs.
    @available(macOS 26.0, *)
    private func makeSliderPill(height: CGFloat) -> GhostGlassPill {
        let big = NSTextField(labelWithString: "A")
        big.font = .boldSystemFont(ofSize: 20); big.textColor = .labelColor
        let small = NSTextField(labelWithString: "a")
        small.font = .systemFont(ofSize: 14); small.textColor = .labelColor
        barMetrics.glyphs += [(big, 20), (small, 14)]

        resSlider.translatesAutoresizingMaskIntoConstraints = false
        setSoftSliderWidth(preferred: 144)

        // Fixed width: the one/all symbols differ slightly and would nudge the bar.
        scopeButton.translatesAutoresizingMaskIntoConstraints = false
        let scopeW = scopeButton.widthAnchor.constraint(equalToConstant: 24)
        scopeW.isActive = true
        barMetrics.lengths.append((scopeW, 24))

        let row = NSStackView(views: [big, resSlider, small, scopeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.setCustomSpacing(14, after: small)
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
        // The pill drives its own contents pink in ghost mode (track + end glyphs).
        g.slider = resSlider
        g.glyphs = [big, small]
        return g
    }


    /// The slider is the bar's one compressible member: a high-priority preferred width
    /// (a low one couldn't grow the bar — the slider hugs its intrinsic size) that
    /// `barMaxWidth` can squeeze, with a breakable floor so it never collapses first.
    private func setSoftSliderWidth(preferred: CGFloat) {
        resSlider.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let pref = resSlider.widthAnchor.constraint(equalToConstant: preferred)
        pref.priority = NSLayoutConstraint.Priority(750)
        let floor = resSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 60)
        floor.priority = NSLayoutConstraint.Priority(900)
        NSLayoutConstraint.activate([pref, floor])
        barMetrics.lengths += [(pref, preferred), (floor, 60)]
    }

    /// Re-tune the unified chrome metrics (same values on every canvas) once bounds settle.
    override func layout() {
        super.layout()
        bannerTop?.constant = state.uniformMenuBarInset + 12
        barMaxWidth?.constant = Self.barWidthCap(minScreenWidth: state.minScreenExtent.width)
        layoutLabelCards()   // overlay subviews track a bounds change (draw never places them)
        onLayout?()          // re-render chrome now that bounds/frames are settled
    }

    /// Place the bar through `chromeViewRect` — the same positioning code as the granny
    /// viewer. The bar is laid out at final size, so `fittingSize` is the on-screen size.
    func layoutBar(in t: Transform) {
        guard let container = barContainer else { return }
        container.layoutSubtreeIfNeeded()
        container.frame = chromeViewRect(finalSize: container.fittingSize,
                                         centreOffsetInches: barCentreOffsetInches, in: t)
    }

    /// The bar centre's offset from the screen centre, in **plane inches** (map-relative,
    /// like the granny viewer — drifts/rescales with the minimap).
    private var barCentreOffsetInches: CGPoint { CGPoint(x: 0, y: -10) }

    /// Lay the bar out at `scale` — its true final size, so every element renders
    /// vector-crisp instead of layer-scaling a rasterised bar (which blurred). No-op when
    /// the scale hasn't changed.
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
            let pt = (base * scale).rounded()   // whole point hints crispest
            glyph.font = bold ? .boldSystemFont(ofSize: pt) : .systemFont(ofSize: pt)
            glyph.wantsLayer = true
            glyph.layer?.contentsScale = backing
        }
        refreshBarIcons()
    }

    /// Base symbol point sizes (at scale 1); icons render at `× barMetrics.currentScale`.
    private var iconPt: CGFloat { 22 }
    private var scopePt: CGFloat { 15 }

    private func symbol(_ name: String, pt: CGFloat, weight: NSFont.Weight = .semibold) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: pt * barMetrics.currentScale, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    /// (Re)render every bar icon at the current scale — rasterised at final point size,
    /// so crisp. Called on setup, state change, and scale change.
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


    /// Live-preview resolution as the slider moves (one display, or all by the same step
    /// delta). Commit on mouse-up.
    @objc private func resSliderChanged() {
        guard let id = selectedID, sliderModes.count > 1 else { return }
        let n = sliderModes.count
        let idx = max(0, min(n - 1, Int((Double(n - 1) * resSlider.doubleValue).rounded())))
        resSlider.doubleValue = Double(idx) / Double(n - 1)   // snap knob to the detent

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
            state.onSliderDragChanged?(false)
        }
    }

    /// Preview every display shifted by `stepDelta` detents from its current mode
    /// (clamped per display), for `.all` scope.
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

    /// Reflect undo availability and sync the slider to the selected display.
    func syncButtons() {
        // `canUndo` is true exactly when there's an edit or pending revert to step back.
        undoButton.isEnabled = state.canUndo
        resetButton.isEnabled = state.canUndo

        // Rebuild icons only when a state symbol actually flips (this runs every notify).
        let feedSymbol = state.feedEnabled ? "figure.run" : "figure.stand"
        if feedSymbol != feedButtonSymbol {
            refreshBarIcons()
        } else {
            scopeButton.image = symbol(state.sliderScope == .all ? "rectangle.stack" : "rectangle", pt: scopePt)
        }

        applyStateIconGhostTint()

        let selected = selectedID.flatMap { id in displays.first(where: { $0.id == id }) }
        sliderModes = selected.map { sortedModes(for: $0) } ?? []
        let usable = sliderModes.count > 1
        resSlider.isEnabled = usable
        if usable, let d = selected {
            let pending = state.pendingMode(for: d.id)
            if let pending, isGhost,
               let idx = sliderModes.firstIndex(where: { ModeCatalog.sameMode(pending, $0.cgMode) }) {
                // A ghost canvas mirrors the live preview (the drag consumes the cursor
                // on the active screen).
                resSlider.doubleValue = Double(idx) / Double(sliderModes.count - 1)
            } else if pending == nil {
                // Not mid-drag: re-sync from the committed mode (never fight a live drag).
                let idx = currentModeIndex(for: d, in: sliderModes) ?? (sliderModes.count - 1) / 2
                resSlider.doubleValue = Double(idx) / Double(sliderModes.count - 1)
            }
        }
    }

    /// Tint the state-driven icons/track for the current ghost mode. Called from both
    /// `syncButtons` and `renderChrome` — the former can run with a stale `isGhost` right
    /// after an active-screen change, so the latter re-applies with the fresh value.
    func applyStateIconGhostTint() {
        let tint: NSColor = isGhost ? VirtualMouse.pink : .labelColor
        feedButton.contentTintColor = tint
        scopeButton.contentTintColor = tint
        (resSlider.cell as? ArrangerSliderCell)?.barTint = isGhost ? VirtualMouse.pink : nil
        resSlider.needsDisplay = true
    }
}
