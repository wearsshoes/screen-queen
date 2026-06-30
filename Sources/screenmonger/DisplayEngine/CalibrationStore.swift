import CoreGraphics
import Foundation

/// Per-display physical-size overrides for when EDID reports a wrong or missing
/// size (common with cheap monitors / dumb adapters). Keyed by display
/// fingerprint so a calibration sticks to that physical monitor across
/// reconnects, and persisted in UserDefaults.
enum CalibrationStore {
    private static let key = "physicalSizeOverridesMM"

    /// fingerprint -> [widthMM, heightMM]
    private static func all() -> [String: [Double]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
    }

    static func override(for fingerprint: String) -> CGSize? {
        guard let v = all()[fingerprint], v.count == 2, v[0] > 0 else { return nil }
        return CGSize(width: v[0], height: v[1])
    }

    static func setOverride(_ size: CGSize, for fingerprint: String) {
        var dict = all()
        dict[fingerprint] = [Double(size.width), Double(size.height)]
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func clearOverride(for fingerprint: String) {
        var dict = all()
        dict[fingerprint] = nil
        UserDefaults.standard.set(dict, forKey: key)
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
