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
    /// The one owner of event monitors and cursor polling (hotkey, ghost-mouse feed,
    /// focus-follows-cursor).
    let events = EventPlumbing()

    var isLiveDragging = false
    /// Snapshot captured when the arranger was opened, for "Reset".
    var baselineOrigins: [CGDirectDisplayID: CGPoint] = [:]
    var baselineModes: [CGDirectDisplayID: CGDisplayMode] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Snappy tooltips (the buttons are icon-only; their tooltips carry the copy, so
        // don't make anyone wait the system's ~1.5s for a punchline). App-scoped, in ms;
        // `register` supplies a default without persisting anything. 666 on purpose.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 666])
        DragFont.register()   // the marquee typeface — not doing this in San Francisco
        PrefsMigration.migrateIfNeeded()   // carry over profiles/calibration from the old bundle id
        setupMenuBar()
        setupArranger()
        events.onHotkeyToggle = { [weak self] in self?.toggleArranger() }
        events.installHotkey()

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

    func applicationWillTerminate(_ notification: Notification) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, context)
        events.teardown()
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

        // The arranger drives (and consumes) the ghost-mouse feed through the shared
        // plumbing; focus follows the cursor across screens (calibration panels first,
        // arranger canvases otherwise).
        arranger.events = events
        events.isCalibrationActive = { [weak self] in self?.calibrationController.isActive ?? false }
        events.focusCalibration = { [weak self] screen in self?.calibrationController.focusPanel(on: screen) }
        events.isArrangerVisible = { [weak self] in self?.arranger.isVisible ?? false }
        events.focusArranger = { [weak self] screen in self?.arranger.focusWindow(on: screen) }
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

    // Hotplug trackers (read/written by AppDelegate+Hotplug.swift; stored properties
    // must live in the class body).
    var lastDisplaySet: Set<String> = []
    /// Base v/m/s (ignoring the topology suffix) of the last set, to detect an
    /// identical monitor joining one already present.
    var lastBaseSet: [String] = []
    /// Session-stable display IDs present last refresh, to find a genuine newcomer.
    var lastDisplayIDs: Set<CGDirectDisplayID> = []
    /// Each display's global origin at the previous refresh, to re-pin survivors when
    /// one leaves (macOS otherwise moves the remaining monitor).
    var lastOrigins: [CGDirectDisplayID: CGPoint] = [:]

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
        events.beginFocusFollowing()
    }
}
