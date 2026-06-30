import CoreGraphics
import Foundation

/// An immutable, value-typed view of a single display at a moment in time.
///
/// This is the unit the whole DisplayEngine traffics in: the read path produces
/// `[DisplaySnapshot]`, the UI renders them, and (in later phases) the write path
/// diffs a desired snapshot against the live one to compute the minimal set of
/// CoreGraphics configuration calls.
struct DisplaySnapshot: Identifiable, Equatable {
    /// CoreGraphics display id. Stable while a display stays connected, but NOT
    /// stable across reconnects — use `fingerprint` for persistence.
    let id: CGDirectDisplayID

    /// Human-readable name (from NSScreen.localizedName), e.g. "DELL U2720Q".
    let name: String

    /// Position + size in the global desktop coordinate space, in points.
    /// Origin is top-left, y grows downward (CoreGraphics global space).
    /// `bounds.size` is the "Looks like" (effective point) resolution.
    let bounds: CGRect

    /// Native backing resolution in pixels.
    let pixelSize: CGSize

    /// Physical size in millimeters. From EDID by default, but replaced by a
    /// user calibration when EDID is missing or wrong (see `CalibrationStore`).
    let physicalSizeMM: CGSize

    /// Whether `physicalSizeMM` came from a manual calibration rather than EDID.
    let physicalSizeIsCalibrated: Bool

    /// Diagonal of the physical size, in inches (0 if size unknown).
    var diagonalInches: Double {
        let w = Double(physicalSizeMM.width), h = Double(physicalSizeMM.height)
        return (w * w + h * h).squareRoot() / 25.4
    }

    let isMain: Bool
    let isBuiltin: Bool

    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    /// Refresh rate in Hz (0 if unknown, e.g. some built-in panels).
    let refreshHz: Double

    /// True when the native pixel resolution exceeds the point resolution,
    /// i.e. the display is running a HiDPI ("Retina"/scaled) mode.
    var isHiDPI: Bool { pixelSize.width > bounds.width }

    /// Physical pixels per inch, derived from EDID. `nil` when the physical
    /// size is missing/implausible.
    var ppi: Double? {
        guard physicalSizeMM.width > 1 else { return nil }
        let inches = Double(physicalSizeMM.width) / 25.4
        guard inches > 0 else { return nil }
        return Double(pixelSize.width) / inches
    }

    /// Effective *points* per physical inch — the density that actually governs
    /// how big a dragged window looks, since macOS preserves a window's point
    /// size across displays. Two screens with equal `pointsPerInch` show a
    /// dragged element at the same physical size. `nil` when EDID size is absent.
    var pointsPerInch: Double? {
        guard physicalSizeMM.width > 1 else { return nil }
        let inches = Double(physicalSizeMM.width) / 25.4
        guard inches > 0 else { return nil }
        return Double(bounds.width) / inches
    }

    /// Stable identity for a physical display across reconnects. Serial is 0 on
    /// some panels; vendor+model still disambiguates most coworking setups.
    var fingerprint: String { "\(vendor)-\(model)-\(serial)" }

    /// A copy repositioned to `origin` — used to build a *prospective* layout for
    /// previewing a drag without actually reconfiguring the displays.
    func movedTo(origin: CGPoint) -> DisplaySnapshot {
        DisplaySnapshot(
            id: id, name: name,
            bounds: CGRect(origin: origin, size: bounds.size),
            pixelSize: pixelSize, physicalSizeMM: physicalSizeMM,
            physicalSizeIsCalibrated: physicalSizeIsCalibrated,
            isMain: isMain, isBuiltin: isBuiltin,
            vendor: vendor, model: model, serial: serial, refreshHz: refreshHz
        )
    }
}
