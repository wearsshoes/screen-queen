import SwiftUI

/// The minimap: every subject drawn at `transform.scale` — tiles, tile seams, tile
/// markers, the label cards that ride the tiles, and the beacon. One per stage,
/// owned by it; being a real type (not Stage extensions) lets the minimap keep its
/// own storage — the caches, the card hosts, the beacon layer.
///
/// The stage stays the input owner and supplies the view-local facts (bounds, the
/// drag-frozen transform, gesture state); the shared editing model comes from `model`.
/// Paint order still lives in the stage's render pass (`Stage.drawSchematic`),
/// which interleaves these subjects with the glass-anchored ones.
@MainActor
final class Minimap {

    /// The stage this minimap draws for (the stage strongly owns the minimap).
    unowned let stage: Stage
    var model: ArrangerModel { stage.model }

    init(stage: Stage) {
        self.stage = stage
    }

    typealias Transform = ArrangerGeometry.Transform

    let tileCornerRadius: CGFloat = 8

    /// The frosted info card per display (see `LabelCard`) — a real backdrop-blur
    /// subview on the stage, repositioned to the tile each frame; created on demand,
    /// hidden when untouched.
    var labelCards: [CGDirectDisplayID: LabelCardHost] = [:]

    /// The beacon: a pulsing pink map-pin at the cursor's location on the tiles.
    var planeMarkerLayer: PlaneMouseMarkerLayer?

    /// Cached native pixel aspect per display (fixed per panel; stale entries harmless).
    var nativeAspectCache: [CGDirectDisplayID: Double?] = [:]

    /// Cached desktop wallpaper per display, keyed by (id, image URL) so changes reload.
    var wallpaperCache: [CGDirectDisplayID: (url: URL, image: NSImage)?] = [:]
}
