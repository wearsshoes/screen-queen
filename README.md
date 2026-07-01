# Silkscreen

**A tiny macOS menu-bar app that arranges your displays by their true physical size — so dragging your cursor between screens finally feels right.**

<!-- TODO: hero GIF of the arranger opening on every screen and a display being dragged/snapped.
     Drop it at docs/demo.gif and uncomment:
![Silkscreen arranger](docs/demo.gif) -->

Plug a 27" 4K monitor next to a 15" laptop and macOS's **Displays** settings arranges
them in an abstract "point" space: the physically huge screen shows up as a tiny box,
cursor transitions land in the wrong place, and windows jump across the seam. Silkscreen
replaces that with an arranger that draws your monitors at their **real relative sizes**,
aligns the seams where your cursor *actually* crosses, and predicts where the Dock will land.

## What it does

- **Physical-size arrangement.** Displays are drawn to true scale, so the layout you build
  matches the monitors on your desk — not macOS's point-space caricature of them.
- **Seam-aware alignment.** Snaps and aligns displays along the edge your cursor really
  crosses, accounting for differing pixel densities between screens.
- **On-every-screen overlay.** Press <kbd>⌘⌥F1</kbd> (or click the 🖥 menu-bar item) and a
  translucent arranger appears on *all* displays at once — you're never trapped in an
  unusable layout.
- **Safe by default.** Resolution, main-display, and mirror changes each arm a countdown
  **revert**, so a bad mode can't strand you.
- **Physical-size calibration.** Monitors lie about their size over EDID. Calibrate a
  screen's true diagonal by typing it in, or by visually matching a box against a trusted
  reference display.
- **Dock prediction.** Shows where the Dock will actually land across your arrangement.
- **Mirroring.** Option-drag one display onto another to mirror it; un-mirror from the tile.
- **Remembers your layouts.** Reconnect the same set of monitors and your arrangement
  restores automatically. Unplug one and the survivors stay put instead of collapsing.
  Plug in a new display and Silkscreen docks it to the nearest free edge and opens so you
  can place it.

## Install

Requires **macOS 14 (Sonoma) or later** (Apple Silicon or Intel).

1. Download `Silkscreen.dmg` from the [latest release](../../releases/latest).
2. Open it and drag **Silkscreen** to your Applications folder.
3. Launch it. It lives in the menu bar (🖥) — there's no Dock icon or window.
4. On first launch macOS will ask for **Accessibility** permission. Silkscreen uses this
   *only* to see the global <kbd>⌘⌥F1</kbd> hotkey while other apps are focused. Grant it
   in **System Settings → Privacy & Security → Accessibility**.

> Silkscreen is notarized by Apple, so Gatekeeper will open it without warnings.

### Build from source

```sh
swift build            # debug build
swift test             # run the layout tests
scripts/dev.sh         # build + launch (add --watch to rebuild on change)
scripts/package.sh     # assemble build/Silkscreen.app (ad-hoc signed)
```

## Using it

Open the arranger with <kbd>⌘⌥F1</kbd> or the menu-bar icon.

- **Drag** a display to move it; it snaps to seams as you go.
- **Arrow keys / WASD** nudge the selected display; <kbd>⌘⇧</kbd> + arrow aligns it to an
  edge anchor (hold <kbd>⌘⇧</kbd> to preview the destinations).
- **<kbd>⌘</kbd> +** <kbd>=</kbd> / <kbd>-</kbd> / <kbd>0</kbd> steps the selected
  display's resolution up / down / to default.
- **Right-click** a display for resolution, main display, mirroring, and calibration.
- **Drag the menu-bar strip** of a tile to make that display the main display.
- **Option-drag** a display onto another to mirror it.
- <kbd>Esc</kbd> / <kbd>Return</kbd> closes the arranger.

## How it works

macOS positions displays in a **point** coordinate space that ignores their physical size,
so a dense 4K panel and a sparse 1080p panel of the same point-dimensions occupy identical
boxes despite being very different physical objects. Silkscreen reads each display's real
size (from EDID, or your calibration), lays your arrangement out on a **physical plane**,
and translates back to the point origins macOS needs — so the seam where your cursor crosses
lines up with the seam between the actual screens. The round-trip between the two coordinate
spaces is covered by the tests in [Tests/SilkscreenTests](Tests/SilkscreenTests).

## License

[MIT](LICENSE) © Rachel Shu
