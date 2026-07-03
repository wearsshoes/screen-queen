# Soft launch (Show HN)

**Blockers:**
* demo GIF — record the arranger, save to docs/demo.gif, uncomment the README image line
* attach notarized build to a GitHub Release

**Before strangers run it (recommended, not blocking):**
* tests for the hotplug/profile logic (handleProfiles, repinSurvivors) — the code most
  likely to silently scramble someone's monitors

**Post-launch (can wait):**
* Homebrew cask
* Sparkle auto-update
* hardware matrix: Intel, clamshell, hub/dock, 3+ monitors, DisplayLink

**SwiftUI port (for someone more familiar — the UI layer is more portable than it looks):**
* Context: the app is almost entirely hand-rolled AppKit + CoreGraphics. On investigation,
  much of the UI layer *could* be SwiftUI; it's AppKit mostly for paradigm consistency,
  low-level control, and the imperative `ArrangerState.changed → needsDisplay` architecture
  mapping 1:1 to AppKit — not because SwiftUI can't do it.
* Genuinely framework-agnostic (stays as-is, called identically from SwiftUI): the display
  guts (`CGDirectDisplay`, `CGDisplayMode`, arrangement/mirroring), event/hotkey plumbing
  (`CGEvent`, `CGEventSource`), ScreenCaptureKit feeds, EDID/PPI via IOKit, Dock config via
  `UserDefaults`. These are Core-level C/system APIs with no UI-framework equivalent.
* Portable to SwiftUI (was AppKit by choice, not necessity):
  - Menu-bar 👑 item + menu → `MenuBarExtra` (first-class now; supports `.window` style for
    rich content). Replaces `NSStatusItem`. Caveat: no programmatic open/close and less
    NSStatusItem control — fine for this menu; global hotkeys stay CGEvent either way.
  - The custom arranger canvas (`Arranger.draw(_:)` — tiles, wallpaper, labels, seam
    glitter, transform math) → SwiftUI `Canvas`, which is immediate-mode and has
    `GraphicsContext.withCGContext` to run the existing CoreGraphics draw code. Biggest
    single piece; the geometry/`Transform` math ports directly. Caveat: `Canvas` closures
    are *stateless* — today's `draw(_:)` also places subviews (solve panel, label cards),
    registers seam emitters, and records hit-test rects, all of which must move out of the
    draw path first (see prep list below).
  - Per-screen borderless overlay windows: NOT portable, keep `ArrangerWindows`. SwiftUI's
    `.windowLevel` (macOS 15+) only offers preset levels — it can't express our
    `mainMenuWindow − 1` — and SwiftUI scenes can't pin one window per screen with exact
    frames, `collectionBehavior`, or the reconfig teardown/rebuild dance. The port seam is
    `window.contentView = NSHostingView(rootView:)` per screen, everything above unchanged.
  - Glass chrome (button bar) → SwiftUI `.glassEffect` / materials. The whole `BarMetrics`
    constraint-scaling machinery dissolves: fonts/spacings as functions of the tile scale
    is SwiftUI's native idiom.
  - Stationary windows (setup/permissions, debug, granny panel, countdown banner) → plain
    SwiftUI views; these have no hard AppKit requirement at all.
  - Stays as NSViewRepresentable indefinitely: the seam sparkle/glow (`CAEmitterLayer` is
    the point), and `Arranger`'s keyboard/drag input until last (gesture parity is the
    riskiest part — port chrome first, Canvas second, input last).
* Prep refactors that make the port mechanical (do these first, as normal cleanups):
  1. Hoist the pure geometry (`Transform`, the fit math, `chromeViewRect`/`chromeTileScale`,
     `ghostPoint`, hit-rect computation) off the NSView into a framework-free
     `ArrangerGeometry` + tests, shared by both implementations.
  2. Make `draw(_:)` side-effect-free (subview placement → refresh/layout path; hit rects →
     pure functions of state). The mirror column is the worst offender.
  3. Collapse `ArrangerState`'s ~15 `onFoo` closures into one `DisplayCommanding` protocol
     (AppDelegate implements); route mutations through named state methods so
     `changed()`/`notify()` can later become `@Observable`.
  4. Gather the seam/ghost/beacon layers behind one `EffectsOverlayView` (inputs: seam
     edges + cursor points) — one representable at port time instead of four layers.
  5. Gather the event plumbing (mouse monitors + slider-drag timer in ArrangerWindows,
     hotkey monitors + debounce in AppDelegate, FocusPolicy) into one `EventPlumbing`
     type: cursor samples / hotkey firings / focus changes come out, nothing else touches
     NSEvent/CGEvent monitors. Isolate by responsibility, not framework — no AppKit
     grab-bag file. (Don't pre-isolate chrome/canvas AppKit; it's replaced wholesale.)
  6. Split AppDelegate (742 lines, three programs in a trenchcoat): the display command
     executor (setResolution(s)/setMain/mirror/commit + applyRevertable/preservingCursor)
     becomes the `DisplayCommanding` impl from #3; the hotplug/profile logic
     (handleProfiles, repinSurvivors, arrangementIsValid, edgeAdjacent, dockNewcomer)
     gets its own file with the pure parts in Domain/ — which is also what unblocks the
     hotplug tests wanted above. App shell (menu, hotkey, launch) stays.
  7. Calibration.swift (1104 lines) wants the same subject split as Arranger
     (controller / panel / tape drawing) — its own pass.
  8. Done (mechanical moves): Arranger+Drawing split into Seams/Tiles/Markers +
     orchestrator; SeamColorBook + palette out of ArrangerState.swift into SeamPalette
     (SeamLights no longer imports the arranger's state file); DragFont → Services;
     systemCPUUsage out of ScreenCaptureManager → Services/SystemLoad; UI/ subfolders
     (Arranger/, Chrome/, Seams/, Calibration/) marking the port's replace-vs-keep line.
* Level assignments (decided; don't relitigate in either direction):
  - Window shell: stays NSWindow. Below it is private SkyLight/CGS — notarization risk,
    breaks across releases. NSWindow is the thinnest *stable* wrapper and it's ~40 lines.
  - Seam particles: stay CAEmitterLayer (render-server GPU, zero app frame loop). Metal is
    the door only if the art direction wants shader glitter someday.
  - Hotkey/mouse: NSEvent monitors + debounce, deliberately. The known upgrade is a
    CGEventTap: one deduped stream, and it can *consume* ⌘⌥F1 instead of leaking it to
    the frontmost app. Cheaper than first assumed — Backstage Pass already requests
    Accessibility (the key monitors need it), and a tap generally rides the same grant
    (verify on a clean machine). Still: switch when something wants the tap's powers
    (consume semantics, or event *injection* — ghost cursor clicking), not before.
* Refs: Apple "Customizing window styles… in macOS", "Canvas" docs; nilcoalescing
  "Build a macOS menu bar utility in SwiftUI".