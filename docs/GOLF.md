# The Golf Ledger

The 2026-07-03 code-golf pass, in two halves. **Landed** is what was obviously safe and
is already committed (each entry one commit, 43 tests green). **The ledger** is
everything that would get simpler if you made a call — combine two things, delete a
half-feature, or make two almost-twins either identical or honestly different. Per your
instruction, the ledger *sets aside* the intentional-design comments in the code: some
entries argue against choices you made on purpose. They're listed anyway; veto freely.

## Landed (commits d299439 → 731d6f5)

- **Calibration**: one key table (`TapeKey.decode` — the tape hosts and the scene view
  each carried the 124/126/123/125/36/76/53 switch), one exit (`finish()` replaces four
  inlined `cancel(); onComplete?()`), one tape factory (the trusted/vanity Copy+palette
  pairing now exists once).
- **Display identity**: `DisplaySnapshot.baseFingerprint` replaces three hand-rolled
  `"\(vendor)-\(model)-\(serial)"` strings; `diagonalInches(_:)` is the one diagonal
  formula; `ppi`/`pointsPerInch` share `perPhysicalInch`; hotplug's `lastOrigins` uses
  `originMap(of:)`; the debug dump snapshots once.
- **Chrome**: every pink call site says `SeamPalette.pink`; `CountdownBannerView.Row`
  replaces the three copies of the banner tuple type; `Stage+Menu.displayItem()`,
  `Ensemble.retireMember()`, SeamLights' two-sided strip loop, EdgeSeams' single
  display lookup.
- **Dead code**: `Copy.menuShowArranger` (orphaned when the house menu moved into the
  bar); label + mirror cards now share `ArrangerState.effectivePPI(_:)`.

**Second wave** (be13feb → 50dbbc7, "do all the non-design ones"): ledger items
**2, 3, 4, 8, 10, 13, 14, 15** landed, plus **12** (sessionPlan, with the aspect-link
invariant now under test — 45 tests total). #9 (DefaultsTable) turned out to be a
design decision after all: unifying the three stores means migrating their on-disk
formats (two plist dicts vs. one JSON blob) or a forced abstraction — moved to the
open list. The banner-rows-array idea (#17) was examined and dropped: the
kind-keyed dictionary + `allCases` ordering is already the simplest true shape.
Remaining open: **1, 5, 6, 7, 9, 11, 16** and the rest of #17 — all genuine
design calls.

**Third wave** (940ab07 → 9730e1d, Rachel ruled on the design calls): **#7**
amputated (Moniker keeps only the XL suffix), **#6** unified (`statLines`, calibrate
prompt on both cards), **#5** merged strict (any failed mode rolls the whole batch
back; `setResolution` is a batch of one), **#9** unified (`DefaultsTable`, JSON blob
per store — formats changed freely pre-release, and **PrefsMigration deleted** with
them), **#11** became `Prefs` (UserDefaults-backed, default on — future Settings
pane), and **#1 Phase 4 landed in its first slice**: `@Observable ArrangerState`;
the solve panel and countdown banner observe state directly (their rootView-rebuild
plumbing deleted); ten Stage forwarding accessors retired.

**Sixth wave (July 2026) — the modern-macOS naming pass + Phase 4 finished.**
`ArrangerState` → **`ArrangerModel`** (type, file, and every `state` property/label —
the post-Observation "MV" convention); resolution interaction moved off Stage into
**`ArrangerModel+Resolution`** with its run state (`zoomPending`, `globalZoomLevel`/
`StartPPI`, `sliderModes`, `sliderDragStartIndex`) now shared — a ⌘⇧ zoom or slider
run survives focus-follows-cursor switching the key stage mid-run (the old latent
bug); `SchematicCanvas.swift` merged into `Stage.swift` as `StageCanvasView`/`Host`
with `repaintCanvas()`/`render(in:size:)`. Phase 4 closed out: the **button bar**
observes the model (BarModel dissolved; rootView rebuilt only for tile scale/ghost/
seam-lights), the **mirror column** observes the model and self-sizes via Auto Layout
(MirrorColumnContent dissolved), and the **canvas** touches its model reads in body
(stage-local drag state still rides `generation`). The **label cards** are the one
deliberate holdout: their content and placement are coupled through `fittingSize`
(height gates visibility, frame centers on the measured size, fonts ride the view
transform), so the refresh-path rebuild is the correct mechanism, not a gap.
`changed()` fan-out survives for AppKit-side work (frames, layers) by design.

**#16** remains the one deliberately open design decision (the two chrome scaling
regimes).

---

## The ledger

Ordered roughly by payoff-per-risk. ⚙️ = mechanical once decided; 🎨 = a real design call.

### 1. 🎨 Phase 4: `@Observable ArrangerState` — ✅ DONE (sixth wave)
Landed across waves five and six: the model is `@Observable ArrangerModel`; the solve
panel, banner, bar, mirror column, and canvas observe it directly; the forwarding
accessors and rootView-rebuild plumbing are mostly gone. What deliberately remains:
the `changed()` fan-out (AppKit frames/layers can't observe), the label cards
(content/placement coupled through `fittingSize` — refresh-path is correct), and
`TapeHost.generation` (calibration's separate input world).

### 2. ⚙️ The axis-duplication family in the layout math
`SchematicLayout` + `SchematicSnapping` + `Stage+TileMarkers` maintain an H copy and a
V copy of the same logic, by hand:
- `VAnchor`/`HAnchor` are the same three-anchor enum twice; `frac()` twice;
  `hPairs`/`vPairs`; `physSnapsH`/`physSnapsV`.
- `SchematicSnapping`: `VMarker`/`HMarker`, the two branches of `dockAndSnap`'s magnet,
  `cornerSnap`, `cycleOrigin`, `wrapOrigin`.
- `Stage+TileMarkers`: `vPos`/`hPos`, `dirV`/`dirH`.

One `Anchor { low, center, high }` plus an axis parameter (along/cross) would halve
~200 lines across four files and make every future seam feature single-source. Cost:
anchors lose their spatial names (`.top` reads better than `.low` until you're in the
horizontal case, where `.left` is *also* `.low` — the rename is arguably a clarity
win), and the layout tests rewrite. This is the highest-value pure refactor after
Phase 4.

Related but riskier: `pinStraddlersOnPlane` / `straddlePointPins` are hand-maintained
mirror images across the commit/interpret boundary (each *also* duplicating x/y
internally). Parametrizing the internal x/y is safe; unifying across the boundary
would blur the "commit and interpret stay faithful inverses" property the comments
lean on — I'd do the internal halving only.

### 3. ⚙️ `DisplayMode` identity → delete `sameMode`
`DisplayMode.id = UUID()` gives every catalog fetch fresh identity, which is why
`ModeCatalog.sameMode(_:_:)` (a five-field comparison) exists and why call sites do
`firstIndex(where: { sameMode(...) })` dances (18 hits). Make identity the value —
`(pixelW, pixelH, pointW, pointH, refresh)` as `Hashable` id — and `sameMode`, plus
every dance around it, deletes. Purely mechanical; only risk is somewhere relying on
two fetches of the same mode being *distinct* (I found none).

### 4. 🎨 `pendingSize` is derivable from `pendingModes`
`previewMode` writes both `pendingModes[id]` and `pendingSize[id]` (the mode's point
size), and every clear-site must remember to clear both. If `pendingModes` stored
`DisplayMode` instead of `CGDisplayMode`, `pointSize(_:)` could read
`pendingModes[id]?.point…` directly and `pendingSize` deletes — one preview state
instead of two that can drift.

### 5. 🎨 `setResolution` vs `setResolutions` — make them the same
`AppDelegate+Commands`: the single-display version is the batch version with stricter
failure semantics (single aborts everything if the mode fails; batch applies whatever
takes, `_ =`). Pick one story — I'd make the batch strict (abort + rollback on any
failed mode; `CGCompleteDisplayConfiguration` already rolls back within one config) —
then `setResolution(id, mode, origins)` becomes `setResolutions([id: mode], origins)`
and ~30 lines of parallel revert bookkeeping delete.

### 6. 🎨 Label card vs mirror card — same stat lines, different fallbacks
Both show nickname / name / `W×H HiDPI` / `NN″ · NN ppi`, now via the shared
`effectivePPI`, but the fallbacks still differ: the label card falls back to
`Copy.calibratePrompt` ("won't say her size"), the mirror card to the bare diagonal
with the `· ` snipped off (`diag.dropLast(3)` — a magic 3 that breaks if the separator
ever changes). Decide one fallback story (I'd show the calibrate prompt in both — a
mirrored girl can lie about her size too) and extract a `DisplayStatLines` builder;
the two cards then differ only in dress.

### 7. 🎨 Moniker's unimplemented promises
`Moniker.nickname(for:isBuiltin:pixelsPerInch:aspectRatio:)` accepts `isBuiltin` and
`pixelsPerInch` and ignores them; the doc comment promises "built-in, dense, or
ultrawide get a suffix" but only ultrawide (`, XL`) exists. Either write the two
missing suffixes or drop the params and the promise. (Callers already compute and pass
the ppi for nothing.)

### 8. ⚙️ The tolerance zoo
The geometry uses at least six unnamed tolerances: `2` (seam/tol in SchematicLayout,
HotplugMath), `0.5` (exact-edge), `1` (preimage dedupe, seam-side match), `1.5`
(planeMatches), `0.1` (currentJoin), `0.05`/`0.01` (assorted). They're each locally
right, but nothing stops a future edit from using the wrong one. One
`enum Tol { static let seam: CGFloat = 2; static let exactEdge = 0.5; … }` in Domain
would name them and make the hierarchy (exact < join < seam) visible.

### 9. ⚙️ Three hand-rolled UserDefaults tables
`LayoutStore`, `CalibrationStore`, `NameStore` each implement the same
`all()`/mutate/`set` dict-in-defaults pattern with different value encodings. A tiny
generic (`DefaultsTable<Value: Codable>`) collapses the three to declarations. Small
win, zero risk; only worth it if you enjoy it.

### 10. ⚙️ `GhostTintable` has one conformer
The protocol was the port-era plan for "every chrome piece restyles pink in its own
look", but the bar/banner went model-flag (`BarModel.isGhost`) and only
`SolvePanelHost` conforms. Either retire the protocol (fold `setGhost` into the host)
or — more honest — move the solve panel's ghost into `SolvePanelContent` like the bar
did, and the special case disappears entirely.

### 11. ⚙️ Always-true feature flags
`Beacon.enabled`, `VirtualMouse.ghostMouseEnabled`, `VirtualMouse.ghostChromeEnabled`
are all `= true` constants guarding live branches. If they're permanent, delete the
flags and the dead `guard`s; if they're meant to be user-facing someday, they should
live together (one `Flags` home) and probably in UserDefaults.

### 12. 🎨 `CalibrationController.begin()` is 130 lines of math + wiring
The seam→edges→pitches→`k`→starting-lengths block is pure and would sit happily in
`CalibrationMath` as a tested `SessionPlan` (inputs: two snapshots + screens' sizes;
outputs: four (length, anchor, pitch) specs + `k`). `begin()` shrinks to tape
construction and wiring, and the aspect-link math — the part most likely to be subtly
wrong — gains tests. The four `onResize` closures are also two mirror pairs; the plan
could express each pair as one link rule.

### 13. ⚙️ Two solves per refresh in the solve panel
`SolvePanelContent(state:)` calls `state.pointOrigins()` *and*
`SchematicLayout.solveTrace(...)` — the trace already computes origins internally
(un-locked, which is why both run). If `solveTrace` accepted the locked-solve origins
(or returned its own), the panel builds from one solve. Also `currentBars()` runs
`pointOrigins()` again in the same refresh — three point-solves per mutation. Cheap
today; will matter if a fourth consumer appears.

### 14. ⚙️ Shared bar-length trim
`miniBarEdges` and `edgeBarEdges` both trim bar ends with
`max(1.5, full − min(cap, full/3))` (caps 8 and 12). One
`SeamEngine.trimmedBarLength(_:cap:)` makes the shared rule visible.

### 15. ⚙️ `nativeAspect` twice
`ModeCatalog.nativeAspect(for:)` and `ResolutionLadder.modesList`'s non-built-in
branch both find the largest-pixel-area mode and take its aspect. Give `[DisplayMode]`
one `nativeMode` helper and both read from it.

### 16. 🎨 The two chrome scaling regimes (your standing decision — listed per your ask)
Minimap-relative chrome (bar/footer/panel ride `chromeTileScale`) vs glass-anchored
chrome (banner, edge markers, tapes in this screen's points). docs/UI.md records this
as deliberate. If you ever flipped the bar/footer/panel to glass-anchored point-space,
`chromeTileScale`, both `chromeViewRect` overloads, `barScale`, and renderChrome's
scale pass (~100 lines) would delete, and the bar would stop changing size when the
map zooms. You chose the current behavior on purpose — the ledger just notes the
price tag.

### 17. ⚙️ Small fry (batch someday, or never)
- `SchematicLayout.seamPhysical` is a pure alias of `piecewise` — keep for the name or
  inline it (one caller + tests).
- `Stage.commitPlane()` / `emitPreview()` are one-line forwards to
  `state.commit()`/`state.notify()` — vocabulary sugar that Phase 4 would absorb.
- `SetupWindow` and `DebugWindow` both hand-manage a build-once/show NSWindow; a
  shared one-off-window helper would cover both.
- `AppDelegate.refresh()` / `refreshAfterCalibration()` / `resetToBaseline()`'s tail
  are three flavors of "snapshot + arranger.refresh"; a `refresh(force:)` with the
  seam-lights hook would unify (note: `refreshAfterCalibration` deliberately skips
  seam lights — correct, since calibration never moves point-space seams; a unified
  version should keep that property explicit rather than accidental).
- Banner rows: the `CountdownKind`-keyed dictionary + `allCases` ordering could be a
  plain ordered array of rows.
- `SeamEmitters`/`SeamGlow` share the begin/seen/commit keyed-layer lifecycle; the
  skeleton could be shared, but the emitter's wake/revive machinery is genuinely its
  own — probably leave.
