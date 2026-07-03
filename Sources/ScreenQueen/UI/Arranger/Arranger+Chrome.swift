import AppKit

/// The per-canvas chrome pass: render the bar/footer/ghost-arrow sizing at this
/// canvas's own tile scale, in normal or ghost dress. Born inside the ghost feature
/// (one set of chrome per canvas, restyled pink when inactive — see VirtualMouse.swift
/// for the projection math), but it's the chrome pipeline; ghost-ness is one input.
extension Arranger {

    /// Render the chrome for this display's mode. `active` is the canvas under the
    /// cursor (nil ⇒ this one is it). All chrome is laid out at this canvas's own tile
    /// scale at its shared anchor spot; ghost mode only changes the tint.
    func renderChrome(active: Arranger?) {
        guard VirtualMouse.ghostChromeEnabled else { return }
        let inactive = active != nil && active !== self
        isGhost = inactive   // so the bar model tints rebuilt icons to match this mode
        let myT = drawTransform(currentRects())
        if inactive, let myT, myT.scale > 0,
           let actT = active!.drawTransform(active!.currentRects()), actT.scale > 0 {
            // Ratio of the two canvases' minimap scales: a cursor beside a tile on the
            // active screen lands beside the matching tile here.
            ghostScale = myT.scale / actT.scale
            ghostActiveCenter = CGPoint(x: active!.bounds.midX, y: active!.bounds.midY)
        } else {
            ghostScale = 1
            ghostActiveCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        // One transform per pass: the bar re-renders at the pass's scale + ghost state
        // (SwiftUI rebuild — tint and sizing are part of the model), then is frame-placed
        // through the same `chromeViewRect` as the granny viewer; the footer tracks the
        // settled bar; the ghost mouse's size rides the same scale.
        if let myT, myT.scale > 0 {
            let k = chromeTileScale(myT)
            updateBar(scale: k)
            layoutBar(in: myT)
            layoutFooter(scale: k)
            if let arrow = ghostArrow {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                arrow.setAffineTransform(CGAffineTransform(scaleX: k, y: k))
                CATransaction.commit()
            }
        } else {
            updateBar()   // no transform yet — still reflect the fresh ghost state
        }
        solvePanel.setGhost(inactive)
    }

    /// Sizes the chrome in proportion to this canvas's minimap tiles: the minimap scale
    /// over a reference, so bigger tiles → bigger bar.
    func chromeTileScale(_ t: Transform) -> CGFloat {
        t.scale / VirtualMouse.referenceMinimapScale
    }

    /// The current tile scale, computing the transform itself; 1 if it isn't ready.
    /// Inside a render pass prefer `chromeTileScale(_:)` with the pass's one transform.
    var chromeTileScale: CGFloat {
        guard let t = drawTransform(currentRects()), t.scale > 0 else { return 1 }
        return chromeTileScale(t)
    }

    /// Round to the nearest whole *device* pixel — a fractional origin smears content
    /// across pixel boundaries.
    func pixelSnap(_ v: CGFloat) -> CGFloat {
        ArrangerGeometry.pixelSnap(v, backingScale: window?.backingScaleFactor ?? 2)
    }
}
