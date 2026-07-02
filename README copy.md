# Drag Queen 👑

**A tiny macOS menu-bar app that arranges your displays by their true physical size — because honey, if you're going to drag, you'd better drag them into the *right* positions.**

<!-- TODO: hero GIF of the queen strutting onto every screen and a display getting dragged, snatched, and put in her place. Drop it at docs/werk.gif and uncomment:
![Drag Queen serving realness](docs/werk.gif) -->

Plug a 27" 4K monitor next to a 15" laptop and macOS's **Displays** settings arranges them
like a straight man packed your suitcase: the physically enormous screen shows up as a tiny
little box, your cursor face-plants into the wrong seam, and windows leap across the gap like
they've seen a bug. It's giving *disorganized*. It's giving *unread group chat*.

Drag Queen replaces that mess with an arranger that draws your monitors at their **real
relative sizes**, aligns the seams where your cursor *actually* crosses, and predicts exactly
where the Dock is going to sashay off to. She does not tuck. She does not compromise.

## What she does

- **Physical-size arrangement.** Displays are drawn to true scale, so the layout matches the
  monitors on your desk — not macOS's flat, padded, point-space *illusion* of them. We see the
  padding, Karen.
- **Seam-aware alignment.** Snaps and aligns displays along the edge your cursor really
  crosses, accounting for differing pixel densities, because size *and* density matter and
  anyone who tells you otherwise is lying.
- **On-every-screen entrance.** Press <kbd>⌘⌥F1</kbd> (or tap the 🖥 in the menu bar) and she
  appears on *all* your displays at once. Full reveal. No warm-up act. You are never trapped
  backstage in an unusable layout.
- **Live preview in each tile.** Every tile shows what's *actually* on that screen in real
  time (its wallpaper when the feed's off), so you can tell your girls apart at a glance. No
  wig mix-ups.
- **Resolution & proportional zoom.** Werk any display's resolution from the tile slider or
  <kbd>⌘</kbd> ±, or zoom *the whole cast* together (<kbd>⌘⇧</kbd> ±) keeping everyone roughly
  proportional in density — all as a live preview that commits as a single undo. One tuck, one
  untuck.
- **Safe by default.** Resolution, main-display, and mirror changes each arm a countdown
  **revert**. If a mode reads for filth and blacks out your screen, she snatches it back before
  anyone gets stranded in the dark. We protect our own.
- **Physical-size calibration.** Monitors *lie* about their size over EDID — bold-faced, on a
  Tuesday. Set the record straight by typing your screen's true diagonal, or by dragging a bar
  until it visually matches a trusted display. Receipts.
- **Dock prediction.** Shows exactly where the Dock is going to end up before it gets there, so
  it can't pull a disappearing act on the wrong monitor.
- **Mirroring.** Option-drag one display onto another and they serve the *same* look on
  purpose — twin gag. Un-mirror from the tile when the number's over.
- **AirPlay-aware.** Clocks an active AirPlay receiver — even a sneaky "Window or App" session
  that isn't even a real display — and puts it on a card. She knows every screen macOS is
  driving. She *always* knows.
- **Remembers your looks.** Reconnect the same monitors and your arrangement struts right back.
  Unplug one and the survivors hold their marks instead of collapsing into a pile. Plug in a
  new one and she docks it to the nearest free edge and opens so you can place it. Nobody gets
  left in the green room.

## Install

Requires **macOS 14 (Sonoma) or later** (Apple Silicon or Intel — she doesn't discriminate).

1. Download `DragQueen.dmg` from the [latest release](../../releases/latest).
2. Open it and drag **Drag Queen** to your Applications folder. (You *drag* her. It's the whole
   bit. Stay with me.)
3. Launch her. She lives in the menu bar (🖥) — no Dock icon, no window, no clutter. A lady
   travels light.
4. On first launch macOS asks for **Accessibility** permission. She uses it *only* to hear the
   global <kbd>⌘⌥F1</kbd> hotkey while other apps have the spotlight. Grant it in
   **System Settings → Privacy & Security → Accessibility**. Consent is sexy.

> Drag Queen is notarized by Apple, so Gatekeeper lets her through without a scene.

### Build from source

```sh
swift build            # debug build (rehearsal)
swift test             # run the layout tests (dress rehearsal)
scripts/dev.sh         # build + launch (add --watch to rebuild on change)
scripts/package.sh     # assemble build/DragQueen.app (ad-hoc signed — full drag)
```

## Using her

Summon the arranger with <kbd>⌘⌥F1</kbd> or the menu-bar icon.

- **Drag** a display to move it; it snaps to seams as you go. (Obviously. It's *right there* in
  the name.)
- **Arrow keys / WASD** nudge the selected display; <kbd>⌘⇧</kbd> + arrow aligns it to an edge
  anchor (hold <kbd>⌘⇧</kbd> to preview where each move lands — look before you leap, gorgeous).
- **<kbd>⌘</kbd> +** <kbd>=</kbd> / <kbd>-</kbd> / <kbd>0</kbd> steps the selected display's
  resolution up / down / to default; add <kbd>⇧</kbd> to zoom the whole ensemble at once.
- **The bottom bar** toggles the live screen feed and whether the slider works one display or
  all of them.
- **Right-click** a display for resolution, main display, mirroring, and calibration — the
  full menu, no bottle service minimum.
- **Drag the menu-bar strip** of a tile to crown that display the main. Long live the queen.
- **Option-drag** a display onto another to mirror it.
- <kbd>Esc</kbd> / <kbd>Return</kbd> and she takes her bow.

## How she works

macOS positions displays in a **point** coordinate space that ignores physical size entirely,
so a dense 4K panel and a sparse 1080p panel of the same point-dimensions occupy identical
boxes — despite being *wildly* different objects in real life. (Padding. It's padding.) Drag
Queen reads each display's real size (from EDID, or your calibration), lays your arrangement out
on a **physical plane**, and translates it back to the point origins macOS demands — so the seam
where your cursor crosses lines up with the seam between the actual screens. The whole illusion
is held together by math and audacity, and the round-trip is covered by the tests in
[Tests/SilkscreenTests](Tests/SilkscreenTests). She rehearses.

## License

[MIT](LICENSE) © Rachel Shu

*No monitors were tucked in the making of this app.*
