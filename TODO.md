~~* doesn't play nice with macbook notch / curved edges~~
~~* when you move the screens and the display is on a non-main screen, the cursor jumps, that's weird.~~
~~* could do some more fancy hotkeying.~~
* ~~want to do it as a windowless popup.~~ done (per-screen arranger overlays)
~~* some of the key actions are wrong.~~
* rename to "screen queen" (?)
* show where the Dock will actually land. It doesn't always sit on the main
  display: macOS flows it to a display touching the main along the Dock's edge
  (bottom by default, or left/right if the Dock is on a side), recursively across
  adjacent screens — except under certain conditions (need to pin these down:
  Dock position setting, which edges actually touch, menu-bar/main interplay).
  Figure out the real rule and draw a Dock indicator on the predicted screen.