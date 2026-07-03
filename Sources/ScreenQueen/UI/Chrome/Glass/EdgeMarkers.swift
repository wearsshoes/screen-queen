import SwiftUI

/// The alignment marker's on-glass half: the active anchor drawn large at *this*
/// screen's real edges, in the window's own point space — the physical counterpart of
/// the minimap notches (Minimap/Stage+TileMarkers, which owns the shared arrow art).
extension Stage {

    /// The active alignment marker for this screen, drawn large at its real edges.
    func drawScreenMarkers(_ ctx: GraphicsContext, _ markers: [CGDirectDisplayID: (pos: Minimap.AnchorPos, dir: CGVector)]) {
        guard let me = centerID, let active = markers[me] else { return }
        let notch = window?.screen?.safeAreaInsets.top ?? 0   // keep clear of the notch on top
        let area = NSRect(x: bounds.minX + 40, y: bounds.minY + 40 + notch,
                          width: bounds.width - 80, height: bounds.height - 80 - notch)
        minimap.drawArrow(ctx, at: active.pos.point(in: area), dir: active.dir, scale: 3)
    }
}
