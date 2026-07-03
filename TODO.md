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
* Port progress (July 2026): ✅ countdown banner (first NSHostingView island),
  ✅ Backstage Pass + debug window, ✅ button bar (ArrangerBarView; BarMetrics /
  HoverGlassView / GhostGlassPill / ArrangerSliderCell dissolved — ghost tint and
  scale are model inputs now), ✅ tooltip bubble (click-through TooltipHost),
  ✅ solve panel (SolvePanelView — first SwiftUI Canvas/GraphicsContext piece,
  the dry run for the big one; y-down point space meant the old flip vanished),
  ✅ the schematic itself (SchematicCanvas: draw(_:) → drawSchematic() inside
  Canvas/withCGContext with one y-flip at the seam; needsDisplay funnels through
  repaintSchematic(); subjects can go native GraphicsContext incrementally).
  Remaining: input last. Two pieces stay AppKit *deliberately*:
  - LabelCard: its text supersamples at 2× backing scale because the script
    hairlines go mushy at 1× on non-Retina panels, and SwiftUI text can't
    express that — revisit only with a non-Retina monitor to check against.
  - Menu-bar item: stays NSStatusItem, NOT MenuBarExtra — corrected verdict.
    Left-click toggles the arranger and right-click pops the menu; MenuBarExtra
    has no left/right split (the earlier "fine for this menu" caveat missed
    that the *click behavior* is the blocker, not the menu content).
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
* Prep refactors that make the port mechanical:
  1. ✅ DONE — `Domain/ArrangerGeometry` (Transform, fit, chrome placement, ghost mapping,
     cursor→plane, pixel snap), framework-free with its own test suite.
  2. ✅ DONE — `draw(_:)` is side-effect-free: cards/solve-panel/seam-effect feeds live on
     the refresh path; the mirror column's hit rects are a pure `mirrorColumnLayout()`.
     (Remaining writes in the render path: `drawTransform`'s drag-freeze cache and the
     wallpaper/aspect memoization — both benign, revisit only if the Canvas port trips.)
  3. ✅ DONE — `DisplayCommanding`: one `state.commander` reference replaces the twelve
     `onFoo` closures; executor lives in AppDelegate+Commands.swift.
     Still open from this item: route remaining direct `state.plane`-poking through named
     ArrangerState methods so `changed()`/`notify()` can become `@Observable`.
  4. ✅ DONE (data-flow half) — seam emitters/glow are fed from the refresh path via pure
     edge sets. NOT boxed into one EffectsOverlayView, deliberately: the solve panel sits
     *between* the effect layers (glow below, beacon/arrow above), so a single sibling
     overlay would break the sandwich. At port time wrap each layer individually.
  5. ✅ DONE — `App/EventPlumbing` owns the hotkey monitors + debounce, the ghost-mouse
     monitors + slider-drag timer, and focus-follows-cursor (FocusPolicy folded in).
     Nothing else installs an NSEvent monitor.
  6. ✅ DONE — AppDelegate split (742 → ~280 shell + Commands + Hotplug); pure hotplug
     rules in `Domain/HotplugMath` with the long-wanted tests (adjacency, validity,
     twin-join, dock placement).
  7. ✅ DONE — Calibration split (controller / panel / tape) + standalone-overlay
     redundancy trimmed: dead CalibrationMath fns, unreachable nil-anchor /
     non-interactive-window fallbacks, seam init reduced to seamEdge; pure pitch
     and size-inference math into CalibrationMath with tests; NSScreen.displayID
     replaces five hand-rolled NSScreenNumber lookups; KeyableBorderlessWindow
     into its own file; BarView renamed TapeView.
  8. ✅ DONE (mechanical moves): Arranger+Drawing split into Seams/Tiles/Markers +
     orchestrator; SeamColorBook + palette out of ArrangerState.swift into SeamPalette
     (SeamLights no longer imports the arranger's state file); DragFont → Services;
     systemCPUUsage out of ScreenCaptureManager → Services/SystemLoad; UI/ subfolders
     (Arranger/, Chrome/, Seams/, Calibration/) marking the port's replace-vs-keep line.
     Also: Beacon split out of VirtualMouse (map marker vs. pointer mirror).
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