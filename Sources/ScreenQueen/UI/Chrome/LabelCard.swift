import SwiftUI

/// What the frosted info card shows: name / resolution / ppi lines with their fonts
/// and colors (NSFont so the canvas's NSString measurement and the card agree on
/// metrics), plus the selection wash.
struct LabelCardContent {
    struct Line {
        let text: String
        let font: NSFont
        let color: NSColor
    }
    var lines: [Line] = []
    var selected = false
    var gap: CGFloat = 3
}

/// The frosted info card on a tile: a real backdrop-blur plate with a translucent
/// wash — pink on the active tile, dark on the rest.
struct LabelCardView: View {
    var content: LabelCardContent

    var body: some View {
        let wash = content.selected
            ? Color(nsColor: NSColor.systemPink.blended(withFraction: 0.35, of: .black) ?? .systemPink).opacity(0.5)
            : Color.black.opacity(0.4)
        VStack(spacing: content.gap) {
            ForEach(Array(content.lines.enumerated()), id: \.offset) { _, line in
                Text(line.text)
                    .font(Font(line.font))
                    .foregroundStyle(Color(nsColor: line.color))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(wash)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// The card's hosting view: decoration only — the tile handles interaction.
final class LabelCardHost: NSHostingView<LabelCardView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(_ content: LabelCardContent) {
        rootView = LabelCardView(content: content)
    }
}
