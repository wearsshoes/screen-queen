# The UI atlas

Every UI file, sorted by the pattern the app actually wants:

```
stage
├─ minimap (the schematic)          plane inches × transform.scale
│  └─ elements that scale with it   chromeTileScale / t.scale
├─ global map (the real desk)       committed point space + physical glass
│  └─ elements that scale with it   this screen's points / PPI
├─ inputs
├─ isolated windows
├─ renderers
└─ copy
```

Two coordinate regimes coexist on every stage. The **minimap** is the shrunk
physical plane (`ArrangerGeometry.Transform`, y-down everywhere). The **global
map** is the real arrangement at real size — the space resolution changes act
in, the space the calibration tapes measure, the space seam lights live in
overnight. Today the minimap has a home (`UI/Arranger/Minimap/`), the on-glass
halves have a home (`UI/Chrome/`), but the *global map itself* has no home —
its conversions and metrics are smeared across four files. That's the root of
most of the weird wiring below.

---

## Stage — the machine (`UI/Arranger/`)

| File | What it is |
|---|---|
| `Stage.swift` | The per-screen flipped NSView. All stored chrome properties, the three re-place entry points (`layout()`, `refresh()`, `renderChrome`), the plane↔view transform plumbing, drag-freeze logic, `ChromeMetrics`. **The god object** — every chrome file extends it; it also forwards ~12 accessors to `ArrangerState` purely so extensions read naturally. |
| `Arranger.swift` | The coordinator: one window per display (fleet build/teardown/reconfig), key routing to the key window's stage, the cursor feed (CGEvent sample → ghost/beacon/tooltip fan-out), feed guard + watchdog, chrome-metrics computation, focus-follows-cursor hook. |
| `ArrangerState.swift` | Shared editing state: the physical plane (source of truth mid-manipulation), selection, previews, drag locks, undo, countdowns, unified chrome metrics, the commit boundary (`SchematicLayout.toPoints`). Framework-free. |
| `SchematicCanvas.swift` | The schematic's SwiftUI `Canvas` host + DragGesture + right-click forwarding, and the render-pass orchestrator `drawSchematic(in:size:)` (paint order for everything below). |
| `Stage+Input.swift` | Mouse drag / menu-bar-strip drag / option-mirror drag; keyboard nudge, alignment, selection. Framework-free — events arrive pre-decoded (`KeyInput`/`ModifierKeys`). |
| `Stage+Resolution.swift` | ⌘± single-display steps, ⌘⇧± global proportional zoom, preview/commit of pending modes. Thin live-system wrapper over `ResolutionLadder`. |
| `Stage+Menu.swift` | The per-tile right-click NSMenu (resolution submenu, calibration entries) + its `@objc` actions. |

## Minimap — its own type (`UI/Arranger/Minimap/`)

`Minimap` is a class, one per stage (owned by it) — not Stage extensions — so its
subjects keep their own storage (caches, card hosts, the beacon layer). The stage
stays the input owner and its render pass sets paint order.

| File | What it is |
|---|---|
| `Minimap.swift` | The type: stage ref, tile corner radius, the caches, card hosts, beacon layer. |
| `Tiles.swift` | Tiles: fill, wallpaper/live feed, letterbox hatching, menu-bar strip, Dock miniature, selected halo — plus label-card layout (subview placement, so refresh-path). |
| `TileSeams.swift` | The mini reference bars flanking each seam, in tile space. |
| `TileMarkers.swift` | The eight anchor notches, paired alignment arrows, ⌘⇧ align-destination ghosts. Owns the shared arrow art (Glass/EdgeMarkers borrows it). |
| `LabelCard.swift` | The frosted info card — position rides the tiles; font scale is `viewScale / ppi` (the true-size preview), the one deliberate crossing of the regimes. |
| `Beacon.swift` | The pulsing map-pin at the cursor's minimap location (cursor → plane → view). Fixed-size art — map pins don't zoom. |

**Scene-referred chrome** — `Chrome/SceneReferred/`: chrome that takes its scale cue
from the scene (size is `chromeTileScale`, position is plane-inches from screen
centre) without being *of* the minimap:

- `ButtonBar.swift` + footer — sized by `chromeTileScale`, placed via `chromeViewRect`.
- `SolvePanel.swift` — natural size × tile scale; its centre is a plane-inch offset in shared state.

## Global map — the real desk

Home: `UI/GlobalMap.swift` — the one CG↔Cocoa flip, the displayID↔NSScreen table,
cursor→host-display, and the uniform Dock/menu-bar insets (landed in the Ensemble
refactor, Phase 1). The calibration edge/placement math lives in
`CalibrationMath.sessionPlan`.

**Glass-anchored chrome** — sorted into `Chrome/Glass/` (this screen's own points
/ PPI; the map can zoom all it wants, these don't move):

| File | What it is |
|---|---|
| `Chrome/Glass/EdgeSeams.swift` | Full-screen bars hugging this screen's real edges; constant *physical* thickness (inches × PPI); rescales during a zoom preview (`axisReal / axisPreview`). |
| `Chrome/Glass/EdgeMarkers.swift` | The active alignment arrow drawn large at this screen's real edges. |
| `Chrome/Glass/CountdownBanner.swift` | Top-of-screen countdown rows on every screen (uniform menu-bar inset). The only chrome placed with Auto Layout constraints — everyone else uses manual frames. |
| `Chrome/Glass/MirrorColumn.swift` | Right-edge column: mirrored-display cards + AirPlay card. Islanded; buttons swallow their own clicks. |
| `Chrome/Glass/TooltipBubble.swift` | The Comic Sans bubble trailing the (ghost) cursor on every stage. Fixed size. |
| `Chrome/Glass/VirtualMouse.swift` | `GhostCursorLayer` (never scales — cursors don't zoom; `Prefs` gates the act). QuartzCore-only. |
| `Calibration/CalibrationTape.swift` | A ruler whose graduations *are* the pitch — the purest glass element in the app (its own windows, same regime). |
| `Seams/SeamLights.swift` | The always-on 2px seam strips — glass geometry rendered as tiny windows. |

## Inputs

- `App/EventPlumbing.swift` — all NSEvent monitors + the slider-drag timer + focus polling. The one NSEvent decode boundary for the arranger (Arranger converts to `KeyInput`/`ModifierKeys`).
- `SchematicCanvas` — DragGesture (mouse), `menu(for:)` forwarding, window keying on mouseDown.
- `Stage+Input` — the framework-free handlers.
- `SolvePanelHost` — its own mouseDown/dragged/up (drag-the-panel), rerouted through state.
- `ButtonBar`'s `.onHover` → `hoveredBarControl` — SwiftUI owns bar hit-testing.
- `TapeHost` (calibration) — its own hit-carving, drag classification, cursor rects, key handling. A second, parallel input system.
- `CalibrationPanel.keyDown` — a third key path (arrow nudges), synced to tape glow via NSNotification observers.

## Isolated windows

| File | What it is |
|---|---|
| `SetupWindow.swift` | Backstage Pass: permissions walkthrough, launch-at-login, relaunch. Standard titled window. |
| `DebugWindow.swift` | Displays/fingerprints/profiles dump. |
| `KeyableBorderlessWindow.swift` | 3-line `canBecomeKey` shim, consumed by Arranger and CalibrationController. |
| `Calibration/CalibrationPanel.swift` | Floating NSPanel HUD per screen: readout, Save/Cancel, arrow-nudge routing. |
| `Calibration/CalibrationController.swift` | The whole calibration session: **its own window fleet**, tape wiring, focus policy, key-glow observers, inferred-size math hand-off. |

## Renderers

| File | What it is |
|---|---|
| `Seams/SeamEngine.swift` | The shared seam machinery: edge registration for both depictions, behind-glow painting, flip-invariant particle directions. |
| `Seams/SeamEmitters.swift` | CAEmitterLayer sparkles, cell-keyed so moving bars leave wakes. GPU, no frame loop. |
| `Seams/SeamGlow.swift` | The tight front glow, one gradient layer per edge, begin/add/commit lifecycle. |
| `UI/SeamPalette.swift` | The house palette (colors only — the lead pink dresses ghost chrome, cursor aids, beacon, tape chalk). |
| `Seams/SeamEngine.swift` | The seam machinery: `SeamColorBook` (the one seam→color assignment) + `ArrangerState.seamColors` + `SeamEngine.committedSeams` (stage-free detection over the real desk) + the Stage-side glow/emitter registration. |
| `GhostCursorLayer`, `PlaneMouseMarkerLayer` | Layer critters in their feature files (VirtualMouse, Beacon). |

## Copy

- `UserTextCopy.swift` — every user-facing string, house voice enforced.
- `Services/Fonts.swift` — ScriptFont registration + `Font.script`.

---

## Where the wiring is weird

Ranked. The first three are real defects or defects-in-waiting; the rest are
structure debt.

1. **`renderChrome` is gated on a ghost feature flag, but it's the only code
   that places the bar.** `Stage.renderChrome` opens with
   `guard VirtualMouse.ghostChromeEnabled else { return }`, and `layoutBar` /
   `layoutFooter` are called nowhere else. Flip that flag off and the button
   bar never gets a frame. "Re-render chrome at my tile scale" and "dress
   inactive stages in pink" are two jobs wearing one guard.

2. **Every state mutation renders the bar twice.** `state.changed` fires
   `refresh()` (which calls `updateBar()`) *and* `rerenderChrome()` (deferred a
   runloop turn, which calls `updateBar(scale:)` + `layoutBar`). The deferral
   exists so autolayout settles — but it means each mutation rebuilds every
   bar's rootView twice, one frame apart, and the first render is at a
   possibly-stale scale.

3. **Three window fleets, three lifecycles.** Arranger (`windows` +
   rebuild-on-reconfig + recreate-not-reposition), CalibrationController
   (refWindow/targetWindow/panels + its own makeWindow + its own focus policy
   + NSNotification key observers), SeamLights (strip windows + signature
   check + its own teardown). Each independently learned the same lessons
   (borderless overlays don't survive `setFrame` across a reconfig;
   `isReleasedWhenClosed = false`; collectionBehavior incantations). The
   duplication is why `KeyableBorderlessWindow` and the CG↔Cocoa flip both
   exist in two places.

4. **The global map has no home.** The CG↔Cocoa flip is written twice
   (`Arranger.cocoaGlobal`, `SeamLights.cocoaRect`), screen metrics live on
   the coordinator, id↔screen lives in a loose extension, and calibration's
   edge geometry reinvents screen-edge placement. All of it is one concept:
   the real desk.

5. **Calibration is a parallel universe.** It predates the y-down flag day and
   still draws y-up under an `NSGraphicsContext` shim inside a Canvas
   (`TapeCanvasView.withCGContext` + flip), keeps its own input system
   (TapeHost hit-carving, cursor rects, key routing), its own focus-follow
   glue (`externallyActive` + four notification observers just to keep a tip
   glow honest), and its own window shells at a different level. The *math*
   is already extracted (`CalibrationMath`, tested); everything around it is
   a second, smaller Screen Queen.

6. **Ghost-mapping state is split across two update cadences.**
   `ghostScale`/`ghostActiveCenter`/`isGhost` are recomputed in `renderChrome`
   (on active-screen *change*) but consumed per-event by
   `updateGhostArrow`/`updateTooltip`. Between a rebuild and the next
   renderChrome the ghost projection is stale. Works today because
   `mouseDidMove` seeds it; the ordering dependency is invisible at the call
   sites.

7. **`Stage` forwards a dozen accessors to state** (`displays`, `selectedID`,
   `pendingSize`…) so extensions read naturally. It blurs ownership — half the
   "Stage" API is actually ArrangerState. With `@Observable` unblocked
   (plane is already `private(set)` + `setPlaneRect`), islands could read
   state directly and the forwarding layer could shrink.

8. **The banner is the one Auto Layout resident.** Constraints + a re-tuned
   `bannerTop` constant in `layout()`, while every sibling is a manual
   pixel-snapped frame. Also `CountdownBannerView.message` reads
   `NSScreen.screens.count` from inside the view — system state belongs in the
   model that builds the view.

9. **`mirrorColumnWidth` lives in Stage's body** while every other mirror-
   column fact lives in MirrorColumn.swift. Residue of the islanding.

10. **`NSImage.asCGImage` lives at the top of Stage+Tiles** — a general
    bridge hiding in a minimap subject file.

---

## The refactor, scoped

Ordered so each phase lands independently, tests green throughout.

### Phase 0 — wiring fixes (small; one sitting)
- Split `renderChrome`'s guard: the tile-scale re-render always runs; only the
  ghost dressing consults `ghostChromeEnabled`. (Finding 1)
- Deduplicate the per-mutation bar render: `refresh()` stops calling
  `updateBar()`; the deferred `rerenderChrome` is the one bar path. (Finding 2)
- Banner: pass screen count through the model; optionally move to manual
  frames like its siblings. (Finding 8)
- Sweep the strays: `mirrorColumnWidth` → MirrorColumn.swift, `asCGImage` →
  wherever bridges live. (Findings 9, 10)

### Phase 1 — give the global map a home (small; mechanical)
New `UI/GlobalMap.swift` (or `Domain/` for the pure parts):
- The one CG↔Cocoa flip (both directions), replacing `cocoaGlobal` and
  `cocoaRect`.
- `NSScreen+DisplayID` folds in (it has Services consumers, so it moves as a
  whole — it does *not* fold into Stage; Stage is a view and never touches
  screens).
- `updateChromeMetrics` + `screenMap` move out of Arranger.
- Cursor→screen resolution (the `CGDisplayBounds.contains` scan) moves here.

### Phase 2 — one fleet (medium; one sitting)
Extract Arranger's window-per-screen machinery into a `Fleet` type:
make/rebuild/teardown per screen, level + content as parameters,
recreate-on-frame-change, `focusWindow(on:)` don't-steal semantics.
`KeyableBorderlessWindow` folds INTO this file — it exists only for fleet
windows. Arranger becomes fleet-consumer #1. SeamLights stays as-is (its
windows are per-*seam* strips, not per-screen; forcing it onto the fleet is
taxonomy for its own sake).

### Phase 3 — calibration joins the world (large; the payoff) — DONE, one amendment
- ~~Tapes port to y-down~~ **Overruled in execution**: the tape-local y-up
  space turned out to be load-bearing — its "along" axis (zero at the inseam
  end) is what keeps the grab/interval math orientation-uniform, and a y-down
  port trades the one boundary flip (TapeHost, where every flip already
  lives) for per-orientation sign conditionals in the interval math. The
  flips stay confined to the host boundary; noted in the Tape header.
- The calibration session became Ensemble-consumer #2: one scrimmed window
  per involved screen at shielding level, tapes as hosted elements, the
  NSPanel replaced by a `CalibrationPanelHost` island on the window. The
  scene view routes window keys (arrows→liar's tape, ⏎/⎋); the per-panel
  NSNotification dance collapsed to one app-wide key-window observer pair
  driving the tip glow.
- Edge-placement conventions (`deskEdge`/`perpendicularEdge`/
  `fullEdgePlacement`) moved to `CalibrationMath` (the pure, tested home) —
  not GlobalMap, which shouldn't speak calibration vocabulary.
- One deliberate loss: the old NSPanel was draggable
  (`isMovableByWindowBackground`); the island is fixed at its placement.
  Re-add island dragging if it's missed.

### Phase 4 — optional long game (flag it, don't start it)
`@Observable ArrangerState`: islands observe state directly, Stage's
forwarding accessors and the `refresh()` fan-out shrink file by file. Biggest
structural win per line deleted, but it changes update *timing* everywhere —
do it after Show HN, not before.

---

## Is there a smarter refactor?

The taxonomy above is the right **vocabulary** but the wrong **work order**.
Reorganizing files by scaling regime is mostly done already (Minimap/ vs the
Edge* files); finishing it buys legibility, not correctness. What the codebase
is actually sick with is **three window fleets and a homeless global map** —
the taxonomy is the symptom chart, the fleet is the disease. So: Phases 1–3
*are* the smart refactor; a literal folder-shuffle to match the outline would
touch 20 files to move information the file headers already carry.

Two pushbacks on the original directives:

- **KeyableBorderlessWindow should fold into the Fleet, not Stage.** Stage is
  a view; it never creates windows. The window shim belongs with the thing
  that makes windows.
- **NSScreen+DisplayID can't fold into Stage either** — DisplayManager and
  ScreenCaptureManager (Services) use it. It folds into the global-map home,
  which Services can legitimately import.

And one deliberate non-goal: don't try to unify the minimap-scaled chrome and
the glass-anchored chrome under one placement system. The bar riding the
minimap while the banner rides the glass is a *design* fact (chrome that
belongs to the map vs chrome that belongs to the screen), not an
inconsistency.
