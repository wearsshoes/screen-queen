import CoreGraphics
import Foundation

/// Per-display physical-size overrides for when EDID reports a wrong or missing
/// size (common with cheap monitors / dumb adapters). Keyed by display
/// fingerprint so a calibration sticks to that physical monitor across
/// reconnects, and persisted in UserDefaults.
enum CalibrationStore {
    private static let table = DefaultsTable<CGSize>(key: "physicalSizeOverridesMM")

    /// All stored calibrations (fingerprint → physical size in mm) — for the debug view.
    static func allOverrides() -> [String: CGSize] {
        table.all().filter { $0.value.width > 0 }
    }

    static func override(for fingerprint: String) -> CGSize? {
        guard let size = table[fingerprint], size.width > 0 else { return nil }
        return size
    }

    static func setOverride(_ size: CGSize, for fingerprint: String) {
        table[fingerprint] = size
    }

    static func clearOverride(for fingerprint: String) {
        table[fingerprint] = nil
    }

    /// Convert a diagonal measurement (inches) into physical width/height in mm,
    /// using the pixel dimensions to pin the aspect ratio.
    static func sizeMM(diagonalInches: Double, pixelWidth: Int, pixelHeight: Int) -> CGSize {
        let pw = Double(pixelWidth), ph = Double(pixelHeight)
        let diagPx = (pw * pw + ph * ph).squareRoot()
        guard diagPx > 0 else { return .zero }
        let widthInches = diagonalInches * pw / diagPx
        let heightInches = diagonalInches * ph / diagPx
        return CGSize(width: widthInches * 25.4, height: heightInches * 25.4)
    }
}
