# Soft launch (Show HN)

**Blockers:**
* demo GIF — record the arranger, save to docs/demo.gif, uncomment the README image line
* attach notarized build to a GitHub Release

**Before strangers run it (recommended, not blocking):**
* ✅ DONE — hotplug/profile decision logic tested (HotplugMath.transition +
  repinDecision, 10 cases; the orchestration just switches on them). Still
  untested (thin, side-effectful): applyProfile / dockNewcomer wiring against
  DisplayManager.

**Post-launch (can wait):**
* Homebrew cask
* Sparkle auto-update
* hardware matrix: Intel, clamshell, hub/dock, 3+ monitors, DisplayLink

**SwiftUI port (July 2026 — one frontier left):**
* The UI layer is SwiftUI now: chrome as NSHostingView islands per canvas
  (banner, button bar + 👑 house menu, tooltip, solve panel, label cards —
  supersampling dropped by decree, Backstage Pass, debug, calibration panel);
  the schematic in a `Canvas` drawing native `GraphicsContext`; input via
  EventPlumbing key monitors + the schematic host's DragGesture (right-click
  forwards to `menu(for:)`). Display guts (`CGDirectDisplay`, CGEvent,
  ScreenCaptureKit, IOKit EDID) were never UI-framework code and are unchanged.
* ✅ Frontier closed: **CalibrationTape** ported (Tape model + Canvas via the
  schematic's shim; TapeHost keeps hit-carving/cursor rects/key routing —
  the tape art can go native GraphicsContext subject-by-subject if wanted).
  Also gone since: the footer NSTextField, NSFont/NSString in the sidebar
  (resolve().measure), Chime (AudioToolbox) for beeps, the NSColor→Color
  push, the y-up view space (everything is y-down now — Transform is a pure
  scale+translate, the Canvas view is flipped, all yDown/flip gates
  deleted), the DragFont bridge (ScriptFont registers via CoreText,
  `Font.script` wears it), and label-card NSString measurement (the card is
  a flex container; the canvas centers its fittingSize on the tile). NSFont
  remains only in the tape art (dies with the tape shim) and TooltipBubble's
  try-Comic-Sans-then-Chalkboard lookup (Font.custom can't express a
  fallible chain); NSColor remains where load-bearing: blended() (Color.mix
  is macOS 15+) and the CALayer palette pipeline.
* AppKit-import census (July 2026, after the framework diet + name swap —
  the per-screen view is **Canvas**, the coordinator is **Arranger**, was
  ArrangerWindows): 13 files, all load-bearing — shells (main, AppDelegate ×2,
  Arranger, KeyableBorderlessWindow, CalibrationController, SeamLights' strip
  windows), events (EventPlumbing), bridges (DisplayManager, NSScreen+DisplayID,
  SeamPalette — the one NSColor home), and the Canvas NSView + its NSMenu.
  UI/Chrome/ files are the overlay cast (view + canvas plumbing per feature,
  or QuartzCore-only layer critters); ArrangerState / Canvas+Resolution /
  Canvas+Input / +Hotplug are framework-free.
* Conventions the port established:
  - One y-down space end to end: plane (`CGDisplayBounds`) = view (Canvas is
    a flipped NSView) = SwiftUI Canvas/gesture space. No flip gates anywhere;
    `Transform` is a pure scale+translate.
  - Repaints go through `repaintSchematic()` (a rootView generation bump) —
    never `needsDisplay`.
  - Text measures via `resolve().measure` in-pass or SwiftUI self-sizing
    (`fittingSize`) for islands; no NSString measurement anywhere.
  - `ArrangerState.plane` is private(set) behind `setPlaneRect(_:for:)`;
    @Observable adoption is unblocked whenever an island wants to observe
    state directly.
* Deliberate AppKit keepers (don't relitigate; each was probed):
  - **Window shell** (Arranger): one borderless NSWindow per display,
    exact frames, `mainMenuWindow − 1`, canJoinAllSpaces/fullScreenAuxiliary.
    SwiftUI scenes can't express any of that; below NSWindow is private
    SkyLight/CGS (notarization risk).
  - **NSStatusItem** (~6 lines): any click toggles the arranger. MenuBarExtra
    can only *show content* on click — `.menu` blocks the runloop, `.window`
    is one popover anchored to the menu-bar screen that dismisses on outside
    click — so it can neither run the toggle nor host the overlay fleet.
  - **Seam particles**: CAEmitterLayer (render-server GPU, zero app frame
    loop). Metal only if the art direction wants shader glitter someday.
  - **EventPlumbing**: NSEvent monitors + debounce. Known upgrade is a
    CGEventTap (consume ⌘⌥F1, event injection); it likely rides the existing
    Accessibility grant — switch only when something needs the tap's powers.
  (LabelCard's supersampling keeper was overruled — ported, hack dropped; if
  script hairlines read mushy on a non-Retina panel, that's the culprit.)
* OS-version policy: floor stays macOS 14; newer-API paths ship as
  default-with-fallback (the macOS-26 glass pattern) *when they earn their
  keep*. Audited July 2026: no macOS-15 API beats what's shipped. Re-audit
  when adding new chrome.
