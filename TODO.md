# Soft launch (Show HN)

**Blockers:**
* demo GIF — record the arranger, save to docs/demo.gif, uncomment the README image line
* attach notarized build to a GitHub Release

**Before strangers run it (recommended, not blocking):**
* tests for the hotplug/profile logic (handleProfiles, repinSurvivors) — the code most
  likely to silently scramble someone's monitors
* let's change the ghost snapping behavior, let's just make it so that whenever a ghost cursor crosses onto any button outside of a drag action, we ghost-highlight that button, and put a ghost cursor onto the active screen there? -- hmm i can see that getting weird with many screens. you tell me what's up.
* switch yellow and pink chalks; x should be yellow y should be pink.
* start at 90% tape length on the trusted screen so the two tapes don't overlap.
* keep the boundary glow on while calibration is going, so the user still knows how to get from screen a to screen b. in fact overall, the calibration tool should just be an overlay over the normal arranger screen, on the most trusted screen and the actively calibrated one.
* also maybe when an unrecognized new screen comes in the measuring tape comes up immediately.
* start at best-guess true length on false screen (length if ppi = trusted screen.) if this is over 90% of false screen, instead shorten trusted screen measuring tape.
* maaaaaaybe add more spaced out dashed lines in the perpendicular direction for x/y, so if the user really wants to flip one of their screens to compare, they can. (so a set of dashier ghost pink lines perpendicular to the primary ones, and the same for yellow)
* bugfix: in "tell me her actual size" we're reporting current guess, not original EDID.
* bugfix: "believe her lies again" doesn't trigger re-render.

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
    rich content). Replaces `NSStatusItem`.
  - The custom arranger canvas (`Arranger.draw(_:)` — tiles, wallpaper, labels, seam
    glitter, transform math) → SwiftUI `Canvas`, which is immediate-mode "very similar to
    drawRect" and has `withCGContext` to run the existing CoreGraphics draw code largely
    unchanged. Biggest single piece; most of the geometry/`Transform` math ports directly.
  - Per-screen borderless overlay windows at a custom level → `.windowLevel(.floating)`
    (macOS 15+) or a thin `NSWindow` bridge; transparent/borderless is a small AppKit hook.
  - Glass chrome (button bar) → SwiftUI `.glassEffect` / materials.
  - Stationary windows (setup/permissions, debug, granny panel, countdown banner) → plain
    SwiftUI views; these have no hard AppKit requirement at all.
* Refs: Apple "Customizing window styles… in macOS", "Canvas" docs; nilcoalescing
  "Build a macOS menu bar utility in SwiftUI"; rampatra "change the window level in SwiftUI".