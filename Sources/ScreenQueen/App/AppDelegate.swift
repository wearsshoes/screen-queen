import AppKit
import CoreGraphics
import IOKit
import IOKit

/// C callback for display hotplug / reconfiguration. Bounces back to the
/// AppDelegate (carried via the `userInfo` context pointer) on the main queue.
private func displayReconfigCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    // `beginConfiguration` fires once before the batch; ignore it to avoid
    // refreshing against a half-applied state.
    if flags.contains(.beginConfigurationFlag) { return }
    // The callback fires once per display in a batch; coalesce into one refresh so
    // we relayout the arranger a single time (no per-display shuffle).
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { delegate.scheduleRefresh() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    // Internal (not private): the command executor lives in AppDelegate+Commands.swift.
    let arranger = ArrangerWindows()
    let calibrationController = CalibrationController()
    let focusPolicy = FocusPolicy()

    var isLiveDragging = false
    /// Snapshot captured when the arranger was opened, for "Reset".
    var baselineOrigins: [CGDirectDisplayID: CGPoint] = [:]
    var baselineModes: [CGDirectDisplayID: CGDisplayMode] = [:]

    private var hotkeyMonitors: [Any] = []
    /// Debounce for the ⌘⌥F1 toggle: the same press can hit both the local and global
    /// monitors (or auto-repeat), which double-toggled. Ignore repeats within a short window.
    private var lastHotkeyToggle: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Snappy tooltips (the buttons are icon-only; their tooltips carry the copy, so
        // don't make anyone wait the system's ~1.5s for a punchline). App-scoped, in ms;
        // `register` supplies a default without persisting anything. 666 on purpose.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 666])
        DragFont.register()   // the marquee typeface — not doing this in San Francisco
        PrefsMigration.migrateIfNeeded()   // carry over profiles/calibration from the old bundle id
        setupMenuBar()
        setupArranger()
        setupHotkey()

        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, context)

        refresh()

        // First run: the Backstage Pass — every permission in one sitting, each with its
        // why, instead of macOS ambushing the user with prompts as features are touched.
        // The arranger's entrance waits until the pass is done; afterwards it's always a
        // menu item away and we never ambush again.
        if !UserDefaults.standard.bool(forKey: Self.didShowSetupKey) {
            UserDefaults.standard.set(true, forKey: Self.didShowSetupKey)
            setupWindow.onDismiss = { [weak self] in
                self?.setupWindow.onDismiss = nil
                self?.showWindow()
            }
            setupWindow.show()
        } else {
            showWindow()
        }
    }

    private static let didShowSetupKey = "didShowSetup"
    private let setupWindow = SetupWindow()

    /// Open the Backstage Pass; the arranger overlay would sit above a normal window,
    /// so take a bow first.
    @objc private func showSetup() {
        dismissArranger()
        setupWindow.show()
    }

    /// ⌘⌥ + Brightness-Down (the F1 key on Mac keyboards) toggles the arranger from
    /// anywhere. That key is a *system-defined* media event, not a plain keyDown. A
    /// local monitor catches it while the arranger is focused, a global one otherwise.
    private func setupHotkey() {
        let handler: (NSEvent) -> Bool = { [weak self] event in
            guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return false }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods == [.command, .option] else { return false }
            // data1: high 16 bits = key code, low bits = state; 0x0A = brightness-down.
            let keyCode = (event.data1 & 0xFFFF0000) >> 16
            let keyDown = (event.data1 & 0xFF00) >> 8 == 0x0A
            guard keyCode == NX_KEYTYPE_BRIGHTNESS_DOWN, keyDown else { return false }
            // When the arranger is open and our app is active, the *same* press can reach
            // both the local and global monitors (and the key can auto-repeat), which
            // toggled twice and appeared to "not close". Collapse bursts to one toggle.
            guard let self else { return true }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastHotkeyToggle > 0.25 else { return true }
            self.lastHotkeyToggle = now
            self.toggleArranger()
            return true
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined, handler: { _ = handler($0) }) {
            hotkeyMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .systemDefined, handler: { handler($0) ? nil : $0 }) {
            hotkeyMonitors.append(l)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, context)
        hotkeyMonitors.forEach { NSEvent.removeMonitor($0) }
    }

    // MARK: - Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = Copy.menuBarGlyph
        // Left-click opens the arranger; right-click shows a menu (just Quit).
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private lazy var statusMenu: NSMenu = {
        let menu = NSMenu()
        // Toggles the arranger; the OS renders the ⌘⌥F1 shortcut greyed at the right.
        let show = NSMenuItem(title: Copy.menuShowArranger, action: #selector(toggleArranger),
                              keyEquivalent: "\u{F704}")   // F1 function key
        show.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(show)
        menu.addItem(withTitle: Copy.menuSetup, action: #selector(showSetup), keyEquivalent: "")
        let lights = NSMenuItem(title: Copy.menuSeamLights, action: #selector(toggleSeamLights(_:)),
                                keyEquivalent: "")
        lights.state = seamLights.enabled ? .on : .off
        menu.addItem(lights)
        // Reveal off-native-aspect (and the built-in's extended) resolutions everywhere.
        let wardrobe = NSMenuItem(title: Copy.menuShowExtendedResolutions,
                                  action: #selector(toggleWardrobe(_:)), keyEquivalent: "")
        wardrobe.state = arranger.state.extendedBuiltinModes ? .on : .off
        wardrobeItem = wardrobe
        menu.addItem(wardrobe)
        menu.addItem(withTitle: Copy.menuDebug, action: #selector(showDebug), keyEquivalent: "")
        menu.addItem(.separator())
        // Version line (disabled): only the bundled app has an Info.plist to read.
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            let item = NSMenuItem(title: "Screen Queen \(v) (\(b))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(withTitle: Copy.menuQuit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }()

    private let debugWindow = DebugWindow()
    @objc private func showDebug() { debugWindow.show() }

    /// The always-on seam lights (see `SeamLights`), rebuilt only from `refresh()`.
    private let seamLights = SeamLights()

    @objc private func toggleSeamLights(_ sender: NSMenuItem) {
        seamLights.enabled.toggle()
        sender.state = seamLights.enabled ? .on : .off
        if seamLights.enabled { seamLights.refresh(displays: DisplayManager.snapshot()) }
    }

    /// The "Show the Full Wardrobe" item — kept so its checkmark can be refreshed each
    /// time the menu opens (the state can also change from within the arranger).
    private weak var wardrobeItem: NSMenuItem?

    @objc private func toggleWardrobe(_ sender: NSMenuItem) {
        arranger.state.extendedBuiltinModes.toggle()
        sender.state = arranger.state.extendedBuiltinModes ? .on : .off
        arranger.state.notify()   // re-derive the slider/menu mode lists everywhere
    }

    @objc private func statusItemClicked() {
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if rightClick {
            wardrobeItem?.state = arranger.state.extendedBuiltinModes ? .on : .off   // may have changed
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)   // pop the menu
            statusItem.menu = nil                  // detach so the next left-click hits our action
        } else {
            toggleArranger()
        }
    }

    /// Open the arranger, or close it if it's already open.
    @objc private func toggleArranger() {
        if arranger.isVisible { dismissArranger() } else { showWindow() }
    }

    private func setupArranger() {
        let s = arranger.state
        s.commander = self   // every display command executes in AppDelegate+Commands
        // A live plane change (drag / nudge / align) marks the session live so the
        // reconfig callback doesn't clobber the working plane.
        let priorChanged = s.changed
        s.changed = { [weak self] in self?.isLiveDragging = true; priorChanged?() }
        calibrationController.onComplete = { [weak self] in self?.refreshAfterCalibration() }

        // Focus follows the cursor across screens (calibration panels first, arranger
        // canvases otherwise) — the policy owns all cursor-screen tracking.
        focusPolicy.isCalibrationActive = { [weak self] in self?.calibrationController.isActive ?? false }
        focusPolicy.focusCalibration = { [weak self] screen in self?.calibrationController.focusPanel(on: screen) }
        focusPolicy.isArrangerVisible = { [weak self] in self?.arranger.isVisible ?? false }
        focusPolicy.focusArranger = { [weak self] screen in self?.arranger.focusWindow(on: screen) }
    }

    /// A calibration edit changes only *physical* size — the point layout is
    /// untouched, so both `refresh()`'s live-drag gate and the arranger's own
    /// no-change detection would swallow the re-render. Force it through.
    func refreshAfterCalibration() {
        isLiveDragging = false
        let displays = DisplayManager.snapshot()
        handleProfiles(displays)
        arranger.refresh(displays: displays, force: true)
    }

    // MARK: - Actions

    @objc func refresh() {
        // Mid-manipulation the shared plane owns the working state; don't clobber it.
        guard !isLiveDragging else { return }
        let displays = DisplayManager.snapshot()
        handleProfiles(displays)
        arranger.refresh(displays: displays)
        // The always-on seam lights follow the committed layout: this runs at launch, on
        // every display reconfiguration, and after every commit — and nowhere else.
        seamLights.refresh(displays: displays)
    }

    private var lastDisplaySet: Set<String> = []
    /// Base v/m/s (ignoring the topology suffix) of the last set, to detect an
    /// identical monitor joining one already present.
    private var lastBaseSet: [String] = []
    /// Session-stable display IDs present last refresh, to find a genuine newcomer.
    private var lastDisplayIDs: Set<CGDirectDisplayID> = []
    /// Each display's global origin at the previous refresh, to re-pin survivors when
    /// one leaves (macOS otherwise moves the remaining monitor).
    private var lastOrigins: [CGDirectDisplayID: CGPoint] = [:]

    /// Auto-save / auto-restore layout profiles. When the connected display *set*
    /// changes (a hotplug), apply the best saved profile for it; otherwise (a settled
    /// state after our own commit) save the current layout as the profile for this set.
    /// If a newly-plugged display isn't covered by any profile, open the arranger and
    /// select it so the user can place it.
    private func handleProfiles(_ displays: [DisplaySnapshot]) {
        let set = Set(displays.map(\.fingerprint))
        let baseSet = displays.map { "\($0.vendor)-\($0.model)-\($0.serial)" }
        let ids = Set(displays.map(\.id))
        let newcomerIDs = ids.subtracting(lastDisplayIDs)
        let removed = lastDisplayIDs.subtracting(ids)
        let priorOrigins = lastOrigins
        defer {
            lastDisplaySet = set; lastBaseSet = baseSet; lastDisplayIDs = ids
            lastOrigins = Dictionary(displays.map { ($0.id, $0.bounds.origin) }, uniquingKeysWith: { a, _ in a })
        }
        guard !set.isEmpty else { return }

        guard set != lastDisplaySet else {
            LayoutStore.store(LayoutStore.profile(from: displays))   // settled → remember this layout
            return
        }

        // A display left: macOS may have moved a survivor to a stale single-monitor
        // layout. Re-pin survivors to their prior positions; if that's impossible
        // (e.g. the middle of three was removed), open the arranger to solve instead.
        if !removed.isEmpty, newcomerIDs.isEmpty {
            repinSurvivors(displays, priorOrigins: priorOrigins)
            return
        }

        // A twin of an already-present monitor just joined: adding it re-suffixes the
        // existing one, but we must NOT reshuffle the existing displays. Leave them put,
        // dock the newcomer flush to the nearest free edge, and arrange it.
        if joinedIdenticalTwin(baseSet) {
            dockNewcomer(newcomerIDs, in: displays)
            selectNewcomer(newcomerIDs, in: displays)
            return
        }

        let profile = LayoutStore.bestMatch(for: Array(set))
        if let profile { applyProfile(profile, to: displays) }

        // Any newly-connected display not covered by the applied profile is
        // "unrecognized" — surface the arranger and select it.
        let recognized = profile.map { Set($0.keys) } ?? []
        let unrecognized = displays.filter { newcomerIDs.contains($0.id) && !recognized.contains($0.fingerprint) }
        selectNewcomer(Set(unrecognized.map(\.id)), in: displays)

        // A brand-new girl gets measured on arrival: if she's external, never
        // calibrated, and this is a genuine hotplug (not launch populating the
        // set), bring the tape out immediately, over the arranger.
        if !lastDisplayIDs.isEmpty,
           let newbie = unrecognized.first(where: { !$0.isBuiltin && !$0.physicalSizeIsCalibrated }) {
            calibrateVisual(newbie.id)
        }
    }

    /// Re-apply the survivors' prior origins so the remaining monitor(s) don't get
    /// moved by macOS's stale layout. If those origins no longer form a valid
    /// arrangement (a gap — e.g. the middle of three was removed), open the arranger to
    /// solve to a next-best layout instead.
    private func repinSurvivors(_ displays: [DisplaySnapshot], priorOrigins: [CGDirectDisplayID: CGPoint]) {
        var rects: [CGRect] = []
        var origins: [CGDirectDisplayID: CGPoint] = [:]
        var mainID: CGDirectDisplayID?
        for d in displays {
            guard let o = priorOrigins[d.id] else { showWindow(); return }   // unknown prior → let user solve
            origins[d.id] = o
            rects.append(CGRect(origin: o, size: d.bounds.size))
            if d.isMain { mainID = d.id }
        }
        guard arrangementIsValid(rects) else { showWindow(); return }        // gap/overlap → solve in arranger
        preservingCursor { DisplayManager.applyOrigins(pin(origins, mainID: mainID), permanent: true) }
    }

    /// Whether `rects` form a connected, non-overlapping arrangement (each touches
    /// another edge-to-edge, none overlap).
    private func arrangementIsValid(_ rects: [CGRect]) -> Bool {
        guard rects.count > 1 else { return true }
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count where rects[i].insetBy(dx: 1, dy: 1).intersects(rects[j].insetBy(dx: 1, dy: 1)) {
                return false   // overlap
            }
        }
        // Connectivity: BFS over edge-adjacency must reach every rect.
        var seen = Set([0]); var queue = [0]
        while let k = queue.popLast() {
            for n in 0..<rects.count where !seen.contains(n) && edgeAdjacent(rects[k], rects[n]) {
                seen.insert(n); queue.append(n)
            }
        }
        return seen.count == rects.count
    }

    private func edgeAdjacent(_ a: CGRect, _ b: CGRect) -> Bool {
        let tol: CGFloat = 2
        let xTouch = abs(a.maxX - b.minX) <= tol || abs(b.maxX - a.minX) <= tol
        let yTouch = abs(a.maxY - b.minY) <= tol || abs(b.maxY - a.minY) <= tol
        let yOv = min(a.maxY, b.maxY) - max(a.minY, b.minY) > tol
        let xOv = min(a.maxX, b.maxX) - max(a.minX, b.minX) > tol
        return (xTouch && yOv) || (yTouch && xOv)
    }

    /// Dock a newly-joined display flush to the nearest free edge of the existing
    /// arrangement (macOS may have dropped it overlapping or off in the void).
    private func dockNewcomer(_ newcomerIDs: Set<CGDirectDisplayID>, in displays: [DisplaySnapshot]) {
        guard let newID = newcomerIDs.first,
              let newD = displays.first(where: { $0.id == newID }) else { return }
        let others = displays.filter { $0.id != newID }
        guard !others.isEmpty else { return }
        let newRect = newD.bounds

        // If the OS spot already touches an edge without overlapping, leave it.
        let overlaps = others.contains { $0.bounds.insetBy(dx: 1, dy: 1).intersects(newRect.insetBy(dx: 1, dy: 1)) }
        let touches = others.contains { edgeAdjacent($0.bounds, newRect) }
        if touches && !overlaps { return }

        // Dock flush to the nearest neighbor's edge without overlapping.
        var best = newRect.origin; var bestDist = CGFloat.greatestFiniteMagnitude
        for o in others {
            let r = o.bounds
            for cand in [CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX - newRect.width, y: r.minY),
                         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY - newRect.height)] {
                let placed = CGRect(origin: cand, size: newRect.size).insetBy(dx: 1, dy: 1)
                if others.contains(where: { $0.bounds.intersects(placed) }) { continue }
                let dist = hypot(cand.x - newRect.minX, cand.y - newRect.minY)
                if dist < bestDist { bestDist = dist; best = cand }
            }
        }
        var origins = originMap(of: displays)
        origins[newID] = best
        let mainID = displays.first(where: \.isMain)?.id
        preservingCursor { DisplayManager.applyOrigins(pin(origins, mainID: mainID), permanent: true) }
    }

    /// True when the base v/m/s multiset grew by exactly one that was already present —
    /// i.e. a second identical monitor was plugged in.
    private func joinedIdenticalTwin(_ baseSet: [String]) -> Bool {
        guard baseSet.count == lastBaseSet.count + 1 else { return false }
        let before = Dictionary(lastBaseSet.map { ($0, 1) }, uniquingKeysWith: +)
        let now = Dictionary(baseSet.map { ($0, 1) }, uniquingKeysWith: +)
        // Exactly one base id increased its count, and it was already present before.
        let grown = now.filter { $0.value > (before[$0.key] ?? 0) }
        return grown.count == 1 && (before[grown.keys.first!] ?? 0) >= 1
    }

    /// Open the arranger (if needed) and select the first newly-connected display.
    private func selectNewcomer(_ newcomerIDs: Set<CGDirectDisplayID>, in displays: [DisplaySnapshot]) {
        guard let id = newcomerIDs.first, displays.contains(where: { $0.id == id }) else { return }
        if !arranger.isVisible { showWindow() }
        arranger.state.selectedID = id
        arranger.state.notify()
    }

    /// Apply a saved profile to the matching connected displays: set each present
    /// display's mode, then its origin (pinning main at 0,0).
    private func applyProfile(_ profile: LayoutStore.Profile, to displays: [DisplaySnapshot]) {
        // `uniqueKeysWithValues` would trap on a fingerprint collision; keep-first
        // instead (the topology suffix should prevent collisions, but degrade safely).
        let byFingerprint = Dictionary(displays.map { ($0.fingerprint, $0) }, uniquingKeysWith: { a, _ in a })
        var origins: [CGDirectDisplayID: CGPoint] = [:]
        var mainID: CGDirectDisplayID?
        preservingCursor {
            for (fp, e) in profile {
                guard let d = byFingerprint[fp] else { continue }
                if let mode = ModeCatalog.mode(for: d.id, matching: e) { DisplayManager.applyMode(mode, to: d.id) }
                origins[d.id] = CGPoint(x: e.originX, y: e.originY)
                if e.isMain { mainID = d.id }
            }
            return DisplayManager.applyOrigins(pin(origins, mainID: mainID), permanent: true)
        }
    }

    private var refreshScheduled = false

    /// Coalesce the per-display reconfig callbacks into one refresh at the end of the
    /// run loop turn, so a batch (e.g. a main-display change) relayouts just once.
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    @objc func showWindow() {
        guard !arranger.isVisible else { return }   // already up — don't rebuild on top
        let displays = DisplayManager.snapshot()
        // Capture the current layout + resolutions as the "Reset" baseline.
        baselineOrigins = originMap(of: displays)
        baselineModes = Dictionary(displays.compactMap { d in
            CGDisplayCopyDisplayMode(d.id).map { (d.id, $0) }
        }, uniquingKeysWith: { a, _ in a })
        arranger.show(displays: displays)
        focusPolicy.begin()
    }
}
