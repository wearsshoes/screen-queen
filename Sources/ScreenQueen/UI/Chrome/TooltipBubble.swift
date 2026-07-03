import SwiftUI

/// The fun tooltip: a white speech-bubble with a hot-pink outline and Comic Sans text,
/// shown on *every* canvas at once via the ghost mapping (a native `NSView.toolTip`
/// would only show on the truly hovered screen). Click-through.
struct TooltipBubbleView: View {
    var text: String

    /// Comic Sans if the system has it, else a rounded fallback that still reads playful.
    private static let font: NSFont =
        NSFont(name: "Comic Sans MS", size: 13)
        ?? NSFont(name: "ChalkboardSE-Regular", size: 13)
        ?? .systemFont(ofSize: 13, weight: .medium)

    var body: some View {
        Text(text)
            .font(Font(Self.font))
            .foregroundStyle(Color(red: 0.86, green: 0.16, blue: 0.5))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color(red: 0.95, green: 0.28, blue: 0.6),
                              lineWidth: 2.5))
            .padding(1.5)   // room so the stroke never kisses the hosting frame
    }
}

/// The bubble's hosting view: decoration only, so clicks fall through to the canvas.
final class TooltipHost: NSHostingView<TooltipBubbleView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
