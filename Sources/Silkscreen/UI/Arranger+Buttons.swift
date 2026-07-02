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
}
