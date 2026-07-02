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
        // dropped for the label; tooltips keep them identifiable. The feed icon is set in
        // syncButtons (it flips between play/stop with the toggle state).
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        resetButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset")
        undoButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo")
        doneButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Done")
        resetButton.toolTip = Copy.resetTooltip; undoButton.toolTip = Copy.undoTooltip; doneButton.toolTip = Copy.doneTooltip
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
        resSlider.toolTip = Copy.sliderTooltip

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
                    ? (NSColor.systemPink.blended(withFraction: 0.6, of: .white)
                        ?? .systemPink).withAlphaComponent(0.4)
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

            // The ghost's twin lookup: circle capsules for the buttons (the visible
            // click surface), the bare controls for slider/scope (fraction matters).
            barCapsules = [.feed: glassy[0], .reset: glassy[1], .undo: glassy[2],
                           .done: glassy[3], .slider: resSlider, .scope: scopeButton]

            let stack = NSStackView(views: pieces)
            stack.orientation = .horizontal
            stack.spacing = 22
            stack.translatesAutoresizingMaskIntoConstraints = false

            let group = NSGlassEffectContainerView()
            group.spacing = 14          // merge distance between neighboring glass shapes
            group.contentView = stack
            container = group
        } else {
            setSoftSliderWidth(preferred: 120)
            // Pre-26 there are no glass capsules (and no scope toggle): the buttons
            // themselves are the ghost's twin surfaces.
            barCapsules = [.feed: feedButton, .reset: resetButton, .undo: undoButton,
                           .done: doneButton, .slider: resSlider]
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
        // Cap the bar to the narrowest screen (constant set in layout()); the slider's
        // soft width above is what gives, so the whole bar compresses identically on
        // every canvas instead of overflowing an extreme-portrait screen.
        barMaxWidth = container.widthAnchor.constraint(lessThanOrEqualToConstant: 100_000)
        barMaxWidth?.isActive = true
        barContainer = container   // for the ghost cursor's bar-relative mapping
    }


    /// A glass pill hosting the resolution slider, flanked by "A" / "a" end glyphs —
    /// wider than the round button capsules, same height.
    @available(macOS 26.0, *)
    private func makeSliderPill(height: CGFloat) -> NSGlassEffectView {
        let big = NSTextField(labelWithString: "A")
        big.font = .boldSystemFont(ofSize: 20); big.textColor = .labelColor
        let small = NSTextField(labelWithString: "a")
        small.font = .systemFont(ofSize: 14); small.textColor = .labelColor

        resSlider.translatesAutoresizingMaskIntoConstraints = false
        setSoftSliderWidth(preferred: 172)

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


    /// The slider is the bar's one compressible member: a soft preferred width the
    /// `barMaxWidth` cap can squeeze, with a firm-but-breakable floor so it never
    /// collapses to nothing before the cap gives up.
    private func setSoftSliderWidth(preferred: CGFloat) {
        let pref = resSlider.widthAnchor.constraint(equalToConstant: preferred)
        pref.priority = .defaultLow
        let floor = resSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 60)
        floor.priority = NSLayoutConstraint.Priority(900)
        NSLayoutConstraint.activate([pref, floor])
    }

    /// Place the bar and banner at the *uniform* anchor offsets (`ArrangerState`'s
    /// unified metrics): the same bottom/top insets and width cap on every canvas, so
    /// the chrome sits at identical anchor-space positions on every screen — never out
    /// of bounds on any of them, however extreme the aspect ratios.
    override func layout() {
        super.layout()
        buttonBarBottom?.constant = -baseBottomMargin - state.uniformDockInset
        bannerTop?.constant = state.uniformMenuBarInset + 12
        barMaxWidth?.constant = Self.barWidthCap(minScreenWidth: state.minScreenExtent.width)
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
    func syncButtons() {
        undoButton.isEnabled = state.canUndo

        // Feed toggle: a running stick figure when live (on), standing when off.
        let feedCfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        let feedSymbol = state.feedEnabled ? "figure.run" : "figure.stand"
        feedButton.image = NSImage(systemSymbolName: feedSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(feedCfg)
        feedButton.contentTintColor = .labelColor
        feedButton.toolTip = state.feedEnabled ? Copy.feedOnTooltip : Copy.feedOffTooltip

        // One/All scope toggle: single rectangle = one display, overlapping = all.
        let scopeCfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let scopeSymbol = state.sliderScope == .all ? "rectangle.on.rectangle" : "rectangle"
        scopeButton.image = NSImage(systemSymbolName: scopeSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(scopeCfg)
        scopeButton.contentTintColor = state.sliderScope == .all ? .systemPink : .secondaryLabelColor
        scopeButton.toolTip = state.sliderScope == .all
            ? Copy.scopeAllTooltip : Copy.scopeOneTooltip

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
}
