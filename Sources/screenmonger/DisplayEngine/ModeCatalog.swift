import CoreGraphics
import Foundation

/// A selectable display mode, with both native pixel and "Looks like" point
/// dimensions so the UI can label scaled (HiDPI) modes the way users expect.
struct DisplayMode: Identifiable {
    let id = UUID()
    let cgMode: CGDisplayMode

    let pixelWidth: Int
    let pixelHeight: Int
    /// "Looks like" point dimensions (what System Settings shows).
    let pointWidth: Int
    let pointHeight: Int
    let refresh: Double

    var isHiDPI: Bool { pixelWidth > pointWidth }

    var label: String {
        var s = "\(pointWidth) × \(pointHeight)"
        if isHiDPI { s += "  (HiDPI)" }
        if refresh >= 1 { s += String(format: "  · %.0f Hz", refresh) }
        return s
    }

    init(_ mode: CGDisplayMode) {
        cgMode = mode
        pixelWidth = mode.pixelWidth
        pixelHeight = mode.pixelHeight
        pointWidth = mode.width
        pointHeight = mode.height
        refresh = mode.refreshRate
    }
}

/// Discovers the display modes available for a display.
///
/// Phase 3 ships the public-API provider (`CGDisplayCopyAllDisplayModes` with
/// duplicate low-res modes shown). The semi-private CoreDisplay provider that
/// surfaces additional synthesized scaled resolutions will conform to the same
/// shape and become a drop-in upgrade.
enum ModeCatalog {

    /// All usable modes for a display, unfiltered.
    static func modes(for id: CGDirectDisplayID) -> [DisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let raw = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else {
            return []
        }
        return raw.filter { $0.isUsableForDesktopGUI() }.map(DisplayMode.init)
    }

    /// The CGDisplayMode on `id` matching a saved profile entry's pixel + point
    /// dimensions (preferring the highest refresh), for restoring a layout profile.
    static func mode(for id: CGDirectDisplayID, matching e: LayoutStore.Entry) -> CGDisplayMode? {
        modes(for: id)
            .filter { $0.pixelWidth == e.pixelWidth && $0.pixelHeight == e.pixelHeight
                   && $0.pointWidth == e.pointWidth && $0.pointHeight == e.pointHeight }
            .max { $0.refresh < $1.refresh }?.cgMode
    }

    /// The panel's native pixel aspect ratio (width / height), from its largest pixel
    /// mode — the reference for detecting letter-/pillar-boxed modes. nil if unknown.
    static func nativeAspect(for id: CGDirectDisplayID) -> Double? {
        guard let native = modes(for: id).max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }),
              native.pixelHeight > 0 else { return nil }
        return Double(native.pixelWidth) / Double(native.pixelHeight)
    }

    /// A deduped, sorted list suitable for a menu: one entry per "Looks like"
    /// size, preferring HiDPI and the highest refresh rate, largest first.
    static func menuModes(for id: CGDirectDisplayID) -> [DisplayMode] {
        var byPointSize: [String: DisplayMode] = [:]
        for m in modes(for: id) {
            let key = "\(m.pointWidth)x\(m.pointHeight)"
            if let existing = byPointSize[key] {
                if (m.isHiDPI ? 1 : 0, m.refresh) > (existing.isHiDPI ? 1 : 0, existing.refresh) {
                    byPointSize[key] = m
                }
            } else {
                byPointSize[key] = m
            }
        }
        return byPointSize.values.sorted {
            $0.pointWidth * $0.pointHeight > $1.pointWidth * $1.pointHeight
        }
    }

    /// Whether two modes are equivalent for the purpose of marking "current".
    static func sameMode(_ a: CGDisplayMode, _ b: CGDisplayMode) -> Bool {
        a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight &&
        a.width == b.width && a.height == b.height &&
        a.refreshRate == b.refreshRate
    }
}
