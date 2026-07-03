import SwiftUI

/// The bottom button bar's canvas-side wiring: the NSHostingView island, model
/// building, slider preview/commit, and frame placement. The bar's look lives in
/// ArrangerBarView (SwiftUI); everything here is state plumbing.
extension Arranger {

    func setupButtonBar() {
        let host = NSHostingView(rootView: makeBarView())
        host.translatesAutoresizingMaskIntoConstraints = true
        addSubview(host)
        barHost = host

        // The instruction line under the bar — a sibling island, positioned + scaled
        // in `layoutFooter`.
        let footer = FooterHost(rootView: FooterView(scale: 1))
        addSubview(footer)
        footerHost = footer
    }

    /// Rebuild the bar from current state. `scale` sticks when given (renderChrome
    /// passes its pass's chromeTileScale; the plain refresh path reuses the last).
    func updateBar(scale: CGFloat? = nil) {
        if let scale { barScale = scale }
        barHost?.rootView = makeBarView()
    }

    private func makeBarView() -> ArrangerBarView {
        ArrangerBarView(model: barModel(), actions: barActions()) { [weak self] control, frame in
            self?.barControlFrames[control] = frame
        }
    }

    private func barModel() -> BarModel {
        var m = BarModel()
        m.scale = barScale
        m.isGhost = isGhost
        m.feedEnabled = state.feedEnabled
        m.scopeAll = state.sliderScope == .all
        m.canUndo = state.canUndo
        m.seamLightsOn = state.commander?.seamLightsOn ?? false
        m.wardrobeOn = state.extendedBuiltinModes
        m.version = Self.versionLine

        let selected = selectedID.flatMap { id in displays.first(where: { $0.id == id }) }
        sliderModes = selected.map { sortedModes(for: $0) } ?? []
        m.sliderEnabled = sliderModes.count > 1
        if m.sliderEnabled, let d = selected {
            let n = sliderModes.count
            // Pending (mid-drag, any canvas) wins; else the committed mode. One rule for
            // every canvas — the ghosts mirror a live drag for free.
            if let pending = state.pendingMode(for: d.id),
               let idx = sliderModes.firstIndex(where: { ModeCatalog.sameMode(pending, $0.cgMode) }) {
                m.sliderValue = Double(idx) / Double(n - 1)
            } else {
                let idx = currentModeIndex(for: d, in: sliderModes) ?? (n - 1) / 2
                m.sliderValue = Double(idx) / Double(n - 1)
            }
        }
        return m
    }

    private func barActions() -> BarActions {
        BarActions(
            feed: { [weak self] in
                guard let self else { return }
                self.state.onToggleFeed?(!self.state.feedEnabled)
            },
            reset: { [weak self] in self?.state.commander?.resetToBaseline() },
            undo: { [weak self] in self?.state.undo() },
            done: { [weak self] in self?.commander?.dismissArranger() },
            scope: { [weak self] in
                guard let self else { return }
                self.state.sliderScope = self.state.sliderScope == .one ? .all : .one
                self.state.notify()   // refresh every canvas so the icon/tooltip update everywhere
            },
            sliderChanged: { [weak self] raw in self?.barSliderChanged(raw) },
            sliderEnded: { [weak self] in self?.barSliderEnded() },
            showSetup: { [weak self] in self?.commander?.showSetup() },
            showDebug: { [weak self] in self?.commander?.showDebug() },
            toggleSeamLights: { [weak self] in
                self?.commander?.toggleSeamLights()
                self?.state.notify()   // re-render the checkmark on every canvas
            },
            toggleWardrobe: { [weak self] in
                guard let self else { return }
                self.state.extendedBuiltinModes.toggle()
                self.state.notify()   // re-derive the slider/menu mode lists everywhere
            },
            quit: { NSApp.terminate(nil) })
    }

    /// Version line for the house menu (nil for the bare dev binary — no Info.plist).
    private static let versionLine: String? = {
        guard let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else { return nil }
        return "Screen Queen \(v) (\(b))"
    }()

    /// The fun copy per control — the single source (no native `.toolTip`; it would pop
    /// on the hovered screen only, doubling up).
    func tooltipText(for control: BarControl) -> String? {
        switch control {
        case .feed:   return state.feedEnabled ? Copy.feedOnTooltip : Copy.feedOffTooltip
        case .reset:  return Copy.resetTooltip
        case .undo:   return Copy.undoTooltip
        case .slider: return Copy.sliderTooltip
        case .scope:  return state.sliderScope == .all ? Copy.scopeAllTooltip : Copy.scopeOneTooltip
        case .done:   return Copy.doneTooltip
        }
    }

    func barControlEnabled(_ control: BarControl) -> Bool {
        switch control {
        case .reset, .undo: return state.canUndo
        case .slider:       return sliderModes.count > 1
        case .feed, .scope, .done: return true
        }
    }

    /// Place the bar through `chromeViewRect` — the same positioning code as the granny
    /// viewer. Width capped so the bar never overflows a narrow screen: the clamped
    /// hosting frame makes SwiftUI propose the capped width and the slider compresses,
    /// identically on every canvas.
    func layoutBar(in t: Transform) {
        guard let host = barHost else { return }
        var size = host.fittingSize
        if state.minScreenExtent.width > 0 {
            size.width = min(size.width, Self.barWidthCap(minScreenWidth: state.minScreenExtent.width))
        }
        host.frame = chromeViewRect(finalSize: size,
                                    centreOffsetInches: barCentreOffsetInches, in: t)
    }

    /// The bar centre's offset from the screen centre, in **plane inches** (map-relative,
    /// like the granny viewer — drifts/rescales with the minimap). +y is down.
    private var barCentreOffsetInches: CGPoint { CGPoint(x: 0, y: 10) }

    /// Position the footer under this canvas's own bar, font scaled with it (text laid
    /// out at the target point size — crisp, not a layer-scaled bitmap). Called from
    /// renderChrome right after `layoutBar`, so the bar frame is settled.
    func layoutFooter(scale s: CGFloat) {
        guard let bar = barHost, let footer = footerHost else { return }
        if footer.rootView.scale != s { footer.rootView = FooterView(scale: s) }
        let size = footer.fittingSize
        footer.frame = CGRect(x: pixelSnap(bar.frame.midX - size.width / 2),
                              y: pixelSnap(bar.frame.maxY + 8 * s),
                              width: size.width, height: size.height)
    }

    // MARK: - Slider preview/commit

    /// Live-preview resolution as the slider moves (one display, or all by the same step
    /// delta): snap the raw 0…1 position to a detent, preview, commit on release.
    private func barSliderChanged(_ raw: Double) {
        guard let id = selectedID, sliderModes.count > 1 else { return }
        let n = sliderModes.count
        let idx = max(0, min(n - 1, Int((Double(n - 1) * raw).rounded())))

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
    }

    private func barSliderEnded() {
        guard sliderDragStartIndex != nil else { return }
        commitPendingResolution()
        sliderDragStartIndex = nil
        state.onSliderDragChanged?(false)
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
        repaintSchematic()
        emitPreview()
    }
}
