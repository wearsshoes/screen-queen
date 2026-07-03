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

    /// What the monitor itself claims over EDID, in millimeters — kept even when a
    /// calibration override wins, because the claim is part of the story (the
    /// match-calibration tape is deliberately ruled in these, her "inches").
    var edidSizeMM: CGSize = .zero

    /// `pointsPerInch` as the EDID claim tells it. `nil` when there is no claim.
    var edidPointsPerInch: Double? {
        guard edidSizeMM.width > 1 else { return nil }
        return Double(bounds.width) / (Double(edidSizeMM.width) / 25.4)
    }

    /// Diagonal of the physical size, in inches (0 if size unknown).
    var diagonalInches: Double { Self.diagonalInches(physicalSizeMM) }

    /// Diagonal of the EDID claim, in inches (0 if she isn't even claiming).
    var edidDiagonalInches: Double { Self.diagonalInches(edidSizeMM) }

    static func diagonalInches(_ mm: CGSize) -> Double {
        let w = Double(mm.width), h = Double(mm.height)
        return (w * w + h * h).squareRoot() / 25.4
    }

    let isMain: Bool
    let isBuiltin: Bool

    /// The display this one mirrors (its mirror-set master), or nil when it isn't a
    /// mirrored slave. A mirrored slave shows the master's image; in the arranger it
    /// leaves the physical plane and lives in the mirror column instead.
    var mirrorMaster: CGDirectDisplayID? = nil

    /// Whether this display is a mirrored slave (mirrors another display).
    var isMirrored: Bool { mirrorMaster != nil }

    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    /// A per-connection suffix (framebuffer location) that distinguishes this display
    /// from another with an identical vendor/model/serial. Empty when there's no such
    /// collision. See `Topology`.
    var fingerprintSuffix: String = ""

    /// Refresh rate in Hz (0 if unknown, e.g. some built-in panels).
    let refreshHz: Double

    /// True when the native pixel resolution exceeds the point resolution,
    /// i.e. the display is running a HiDPI ("Retina"/scaled) mode.
    var isHiDPI: Bool { pixelSize.width > bounds.width }

    /// Physical pixels per inch, derived from EDID. `nil` when the physical
    /// size is missing/implausible.
    var ppi: Double? { perPhysicalInch(pixelSize.width) }

    /// Effective *points* per physical inch — the density that actually governs
    /// how big a dragged window looks, since macOS preserves a window's point
    /// size across displays. Two screens with equal `pointsPerInch` show a
    /// dragged element at the same physical size. `nil` when EDID size is absent.
    var pointsPerInch: Double? { perPhysicalInch(bounds.width) }

    private func perPhysicalInch(_ extent: CGFloat) -> Double? {
        guard physicalSizeMM.width > 1 else { return nil }
        return Double(extent) / (Double(physicalSizeMM.width) / 25.4)
    }

    /// vendor/model/serial — the identity shared by physically identical monitors
    /// (calibration keys on this; `fingerprint` adds the per-connection suffix).
    var baseFingerprint: String { "\(vendor)-\(model)-\(serial)" }

    /// Stable identity for a physical display across reconnects: vendor/model/serial,
    /// plus a per-connection topology suffix when two connected monitors would
    /// otherwise share it (see `Topology`).
    var fingerprint: String {
        fingerprintSuffix.isEmpty ? baseFingerprint : "\(baseFingerprint)@\(fingerprintSuffix)"
    }

    /// Her drag name: stable, deterministic from the fingerprint, forever the same monitor
    /// forever the same girl. The suffix reacts to what she actually is.
    var nickname: String {
        let aspect = bounds.height > 0 ? Double(bounds.width / bounds.height) : nil
        return Moniker.nickname(for: fingerprint, aspectRatio: aspect)
    }

    /// A copy with new `bounds` — for building a *prospective* layout (drag or
    /// resolution preview) without actually reconfiguring the displays.
    func with(bounds: CGRect) -> DisplaySnapshot {
        DisplaySnapshot(
            id: id, name: name, bounds: bounds,
            pixelSize: pixelSize, physicalSizeMM: physicalSizeMM,
            physicalSizeIsCalibrated: physicalSizeIsCalibrated,
            edidSizeMM: edidSizeMM,
            isMain: isMain, isBuiltin: isBuiltin,
            mirrorMaster: mirrorMaster,
            vendor: vendor, model: model, serial: serial,
            fingerprintSuffix: fingerprintSuffix, refreshHz: refreshHz
        )
    }

    func movedTo(origin: CGPoint) -> DisplaySnapshot {
        with(bounds: CGRect(origin: origin, size: bounds.size))
    }
}
