import SwiftUI

/// Identity of each bar control — tooltip hit-testing and frame reporting key off these.
enum BarControl: Hashable, CaseIterable {
    case feed, reset, undo, slider, scope, done
}

/// Everything the bar renders from. Plain values: the stage rebuilds the rootView on
/// every refresh/renderChrome pass, so the bar is a pure function of this.
struct BarModel: Equatable {
    var scale: CGFloat = 1        // chromeTileScale — every length/font multiplies by it
    var isGhost = false           // pink chrome on inactive stages
    var feedEnabled = true
    var scopeAll = false
    var canUndo = false
    var sliderValue = 0.5         // 0…1, detent-snapped upstream
    var sliderEnabled = false
    // House-menu state (the status item is a plain toggle; the menu lives here).
    var seamLightsOn = false
    var wardrobeOn = false
    var version: String?
}

/// The bar's outbound wiring, kept out of the model so Equatable stays derivable.
struct BarActions {
    var feed: () -> Void = {}
    var reset: () -> Void = {}
    var undo: () -> Void = {}
    var done: () -> Void = {}
    var scope: () -> Void = {}
    var sliderChanged: (Double) -> Void = { _ in }
    var sliderEnded: () -> Void = {}
    var showSetup: () -> Void = {}
    var showDebug: () -> Void = {}
    var toggleSeamLights: () -> Void = {}
    var toggleWardrobe: () -> Void = {}
    var quit: () -> Void = {}
}

/// The bottom button bar (feed · reset · undo · [resolution slider] · done): Liquid
/// Glass capsules on macOS 26, one HUD box below. All chrome sizes are functions of
/// `model.scale` — the SwiftUI replacement for the old BarMetrics constraint mutation.
struct ButtonBarView: View {
    var model: BarModel
    var actions = BarActions()
    /// Reports hover per control (SwiftUI owns the hit-testing), for the ghost tooltip.
    var onControlHover: (BarControl, Bool) -> Void = { _, _ in }

    private var k: CGFloat { model.scale }
    private var pink: Color { ChromeMetrics.ghostPink }

    var body: some View {
        // No width cap here: `layoutBar` clamps the hosting frame to `barWidthCap`,
        // which makes SwiftUI propose the capped width and the slider compress.
        Group {
            if #available(macOS 26.0, *) {
                glassBar
            } else {
                hudBar
            }
        }
    }

    // MARK: - macOS 26: separate glass capsules that merge when close

    @available(macOS 26.0, *)
    private var glassBar: some View {
        GlassEffectContainer(spacing: 14 * k) {
            HStack(spacing: 22 * k) {
                circleButton(.feed, symbol: model.feedEnabled ? "figure.run" : "figure.stand",
                             action: actions.feed)
                circleButton(.reset, symbol: "arrow.counterclockwise", enabled: model.canUndo,
                             shortcut: KeyboardShortcut(.delete, modifiers: .command),
                             action: actions.reset)
                circleButton(.undo, symbol: "arrow.uturn.backward", enabled: model.canUndo,
                             shortcut: KeyboardShortcut("z", modifiers: .command),
                             action: actions.undo)
                sliderPill
                circleButton(.done, symbol: "checkmark", prominent: true,
                             shortcut: .defaultAction,
                             action: actions.done)
                houseMenu
                    .frame(width: 56 * k, height: 56 * k)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
        }
    }

    /// A chromeless icon button whose glass capsule *is* the surface; `.interactive()`
    /// supplies the hover/press response the old HoverGlassView hand-rolled.
    @available(macOS 26.0, *)
    private func circleButton(_ id: BarControl, symbol: String, enabled: Bool = true,
                              prominent: Bool = false, shortcut: KeyboardShortcut? = nil,
                              action: @escaping () -> Void) -> some View {
        let d = 56 * k
        // A lighter accent so the clear glass stays see-through on Done.
        let doneTint = Color(nsColor: (NSColor.systemPink.blended(withFraction: 0.6, of: .white)
            ?? .systemPink).withAlphaComponent(0.4))
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22 * k, weight: .semibold))
                .foregroundStyle(iconColor(enabled: enabled))
                .frame(width: d, height: d)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .modifier(OptionalShortcut(shortcut: shortcut))
        .glassEffect(prominent ? .regular.tint(doneTint).interactive() : .regular.interactive(),
                     in: Circle())
        .reportHover(id, to: onControlHover)
    }

    /// The glass pill hosting the resolution slider, flanked by "A" / "a" end glyphs
    /// and the one/all scope toggle.
    @available(macOS 26.0, *)
    private var sliderPill: some View {
        HStack(spacing: 8 * k) {
            Text("A").font(.system(size: 20 * k, weight: .bold)).foregroundStyle(glyphColor)
            slider
            Text("a").font(.system(size: 14 * k)).foregroundStyle(glyphColor)
            scopeButton.padding(.leading, 6)
        }
        .padding(.horizontal, 20 * k)
        .frame(height: 56 * k)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    // MARK: - Pre-26: one HUD box

    private var hudBar: some View {
        HStack(spacing: 12 * k) {
            plainButton(.feed, symbol: model.feedEnabled ? "figure.run" : "figure.stand",
                        action: actions.feed)
            plainButton(.reset, symbol: "arrow.counterclockwise", enabled: model.canUndo,
                        shortcut: KeyboardShortcut(.delete, modifiers: .command),
                        action: actions.reset)
            plainButton(.undo, symbol: "arrow.uturn.backward", enabled: model.canUndo,
                        shortcut: KeyboardShortcut("z", modifiers: .command),
                        action: actions.undo)
            slider
            scopeButton
            plainButton(.done, symbol: "checkmark", shortcut: .defaultAction,
                        action: actions.done)
            houseMenu
                .frame(width: 44 * k, height: 44 * k)
        }
        .padding(.vertical, 12 * k)
        .padding(.horizontal, 16 * k)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22 * k, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22 * k, style: .continuous)
            .strokeBorder(model.isGhost ? pink : Color.white.opacity(0.12),
                          lineWidth: model.isGhost ? 1.5 : 0.5))
    }

    private func plainButton(_ id: BarControl, symbol: String, enabled: Bool = true,
                             shortcut: KeyboardShortcut? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22 * k, weight: .semibold))
                .foregroundStyle(iconColor(enabled: enabled))
                .frame(width: 44 * k, height: 44 * k)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .modifier(OptionalShortcut(shortcut: shortcut))
        .reportHover(id, to: onControlHover)
    }

    // MARK: - Shared pieces

    /// The house menu — Backstage Pass, seam lights, wardrobe, debug, version, Quit.
    /// Lives in the bar because the status item is a plain arranger toggle now.
    private var houseMenu: some View {
        Menu {
            Button(Copy.menuSetup, action: actions.showSetup)
            Toggle(Copy.menuSeamLights, isOn: Binding(
                get: { model.seamLightsOn }, set: { _ in actions.toggleSeamLights() }))
            Toggle(Copy.menuShowExtendedResolutions, isOn: Binding(
                get: { model.wardrobeOn }, set: { _ in actions.toggleWardrobe() }))
            Button(Copy.menuDebug, action: actions.showDebug)
            Divider()
            if let version = model.version { Text(version) }
            Button(Copy.menuQuit, action: actions.quit)
        } label: {
            Image(systemName: "crown")
                .font(.system(size: 20 * k, weight: .semibold))
                .foregroundStyle(iconColor(enabled: true))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var slider: some View {
        BarSlider(value: model.sliderValue, enabled: model.sliderEnabled,
                  fill: model.isGhost ? pink : Color.accentColor, k: k,
                  onChanged: actions.sliderChanged, onEnded: actions.sliderEnded)
            .frame(minWidth: 60 * k, idealWidth: 144 * k, maxWidth: 144 * k)
            .reportHover(.slider, to: onControlHover)
    }

    private var scopeButton: some View {
        Button(action: actions.scope) {
            Image(systemName: model.scopeAll ? "rectangle.stack" : "rectangle")
                .font(.system(size: 15 * k, weight: .semibold))
                .foregroundStyle(iconColor(enabled: true))
                .frame(width: 24 * k, height: 24 * k)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .reportHover(.scope, to: onControlHover)
    }

    /// Ghost mode tints only the *icon* — a washed capsule read as a solid pink blob.
    private func iconColor(enabled: Bool) -> Color {
        guard enabled else { return .secondary }
        return model.isGhost ? pink : Color.primary
    }

    private var glyphColor: Color { model.isGhost ? pink : Color.primary }
}

/// The resolution slider, drawn by hand: the stock control dims in non-key windows and
/// only one arranger overlay is key at a time — the same reason the old ArrangerSliderCell
/// existed. Left = larger UI, right = more space (matching macOS). Reports the raw 0…1
/// position; detent snapping/preview lives on the stage.
private struct BarSlider: View {
    var value: Double
    var enabled: Bool
    var fill: Color
    var k: CGFloat
    var onChanged: (Double) -> Void
    var onEnded: () -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let knob = 20 * k
            let trackH = 4 * k
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                    .frame(height: trackH)
                Capsule().fill(fill)
                    .frame(width: max(0, CGFloat(value) * (w - knob) + knob / 2), height: trackH)
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 1.5 * k, y: 0.5 * k)
                    .frame(width: knob, height: knob)
                    .offset(x: CGFloat(value) * (w - knob))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard enabled, w > knob else { return }
                    let raw = (g.location.x - knob / 2) / (w - knob)
                    onChanged(Double(min(max(raw, 0), 1)))
                }
                .onEnded { _ in
                    guard enabled else { return }
                    onEnded()
                })
        }
        .frame(height: 20 * k)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// The instruction line under the bar (see `Copy.footer`), font-scaled with it.
struct FooterView: View {
    var scale: CGFloat
    var body: some View {
        Text(Copy.footer)
            .font(.system(size: (11 * scale).rounded()))   // whole-point hints crispest
            .foregroundStyle(.tertiary)
            .fixedSize()
    }
}

/// Decoration only — clicks fall through to the stage.
final class FooterHost: NSHostingView<FooterView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// `.keyboardShortcut` can't take an optional; this applies one when present.
private struct OptionalShortcut: ViewModifier {
    let shortcut: KeyboardShortcut?
    func body(content: Content) -> some View {
        if let shortcut { content.keyboardShortcut(shortcut) } else { content }
    }
}

private extension View {
    /// Report this control's hover state, tagged with its identity.
    func reportHover(_ control: BarControl,
                     to report: @escaping (BarControl, Bool) -> Void) -> some View {
        onHover { report(control, $0) }
    }
}

// MARK: - Stage plumbing (model building, actions, placement, slider preview/commit)

/// The bottom button bar's stage-side wiring: the NSHostingView island, model
/// building, slider preview/commit, and frame placement. The bar's look lives in
/// ButtonBarView (SwiftUI); everything here is state plumbing.
extension Stage {

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

    private func makeBarView() -> ButtonBarView {
        ButtonBarView(model: barModel(), actions: barActions()) { [weak self] control, hovering in
            guard let self else { return }
            if hovering { self.hoveredBarControl = control }
            else if self.hoveredBarControl == control { self.hoveredBarControl = nil }
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
            // Pending (mid-drag, any stage) wins; else the committed mode. One rule for
            // every stage — the ghosts mirror a live drag for free.
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
                self.state.notify()   // refresh every stage so the icon/tooltip update everywhere
            },
            sliderChanged: { [weak self] raw in self?.barSliderChanged(raw) },
            sliderEnded: { [weak self] in self?.barSliderEnded() },
            showSetup: { [weak self] in self?.commander?.showSetup() },
            showDebug: { [weak self] in self?.commander?.showDebug() },
            toggleSeamLights: { [weak self] in
                self?.commander?.toggleSeamLights()
                self?.state.notify()   // re-render the checkmark on every stage
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
    /// identically on every stage.
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

    /// Position the footer under this stage's own bar, font scaled with it (text laid
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
