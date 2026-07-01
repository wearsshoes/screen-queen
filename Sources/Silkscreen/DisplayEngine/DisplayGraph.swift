import AppKit
import CoreGraphics

/// Per-display palette assignment. Seam detection now lives in `SchematicLayout`
/// (which works in physical space); this just hands each display a stable color.
enum DisplayGraph {

    static let palette: [NSColor] = [
        .systemPink, .systemGreen, .systemBlue, .systemOrange,
        .systemPurple, .systemTeal, .systemYellow, .systemRed
    ]

    /// Assign each display a distinct palette color, keyed to a stable id order.
    /// Distinct-by-index (rather than minimal graph coloring) keeps colors stable
    /// while dragging and guarantees neighbors always differ for any realistic
    /// monitor count.
    static func colors(_ displays: [DisplaySnapshot]) -> [CGDirectDisplayID: NSColor] {
        var assigned: [CGDirectDisplayID: NSColor] = [:]
        for (i, d) in displays.sorted(by: { $0.id < $1.id }).enumerated() {
            assigned[d.id] = palette[i % palette.count]
        }
        return assigned
    }
}
