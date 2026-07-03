# Soft launch (Show HN)

**Blockers:**
* demo GIF — record the arranger, save to docs/demo.gif, uncomment the README image line
* attach notarized build to a GitHub Release

**Before strangers run it (recommended, not blocking):**
* ✅ DONE — hotplug/profile decision logic tested: the branch selection
  (HotplugMath.transition) and repin apply-vs-solve (repinDecision) are pure
  with 10 cases; the orchestration in AppDelegate+Hotplug just switches on
  them. Still untested (thin, side-effectful): applyProfile / dockNewcomer
  wiring against DisplayManager.

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
  ✅ the schematic itself (SchematicCanvas; needsDisplay funnels through
  repaintSchematic()), ✅ the FULL draw pass gone native GraphicsContext (July
  2026): wash/message/drag overlays, markers, tiles (Image + clip + opacity,
  even-odd hatch, .shadow-filter halo), mirror column (NSString measurement
  kept, drawing native, inline-Text symbol baseline), and the behind-glows
  (drawLayer + .destinationOut feathers). The legacyDraw shim is deleted —
  no NSGraphicsContext.current anywhere in the render pass. Convention:
  geometry computes y-up (Transform/hit-test space), flips at each subject's
  draw boundary (yDown / yDownPoint / yDownDir).
  ✅ input port phases 1+2 (keys via EventPlumbing monitors; mouse via the
  schematic host's DragGesture; right-click forwards to menu(for:)).
  ✅ PORT COMPLETE for the render/chrome layer. Input verdict, REVISED
  (Rachel's challenge was right): input CAN leave the NSView responder chain
  without macOS 15 —
  - keys: onKeyPress(phases:) is macOS 14+, covers arrows/WASD down/up/repeat;
    shortcuts already ride .keyboardShortcut;
  - modifier-release commits (⌘⇧ align, ⌘ resolution): not keypresses, but
    EventPlumbing already owns NSEvent monitors — a flagsChanged monitor there
    is *lower*-level than the responder chain, matching where the weird mouse
    stuff (CGEvent cursor sampling, cursor warping) already lives;
  - drags (tile / menu-bar strip / option-mirror): SwiftUI gestures on the
    schematic host; window-keying stays in ArrangerWindows (focus-follows-
    cursor already keys on hover, mouseDown's makeKey is nearly redundant).
  What keeps it parked is RISK, not feasibility: undo-snapshot timing,
  drag-lock windows, and commit ordering are the app's most regression-prone
  semantics. Sequenced post-launch; don't fold it into the Show HN push.
  Other pieces that stay AppKit *deliberately*:
  - LabelCard: its text supersamples at 2× backing scale because the script
    hairlines go mushy at 1× on non-Retina panels, and SwiftUI text can't
    express that — revisit only with a non-Retina monitor to check against.
  - Menu-bar item: a plain NSStatusItem toggle (~6 lines) — any click opens the
    arranger. The old right-click menu moved into the bar as a SwiftUI Menu (the
    👑 capsule): Stage Pass, seam lights, wardrobe, debug, version, Quit.
    MenuBarExtra still isn't it — it can't run an action on click, only show
    content — but with the menu living in the bar there's nothing left to port.
    Also probed (July 2026): MenuBarExtra(.window) can't *be* the overlays —
    it's one popover-anchored window on the menu-bar screen that dismisses on
    outside click, with no NSWindow access to re-frame/re-level; the arranger
    is five exact-frame full-screen windows at mainMenuWindow−1 where clicking
    "outside" is the interaction.
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
     Sub-task ✅ DONE too: `plane` is private(set), mutations go through
     `setPlaneRect(_:for:)` — @Observable adoption is unblocked whenever a
     SwiftUI island wants to observe state directly.
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
* OS-version policy (decided): floor stays macOS 14; newer-API paths go in as
  default-with-fallback (the macOS-26 glass pattern) *when they earn their keep*.
  Audited July 2026: no macOS-15 API currently beats what's shipped — input's
  onModifierKeysChanged would mean two divergent input state machines, and
  appearsActive only matters for stock controls (the bar's are custom-drawn so
  they never dim). Re-audit when adding new chrome.
* Refs: Apple "Customizing window styles… in macOS", "Canvas" docs; nilcoalescing
  "Build a macOS menu bar utility in SwiftUI".