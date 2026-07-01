import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics

/// Reads the raw EDID for a display via IOKit and hashes it, for a per-unit
/// fingerprint that's stronger than CoreGraphics' vendor/model/serial (which
/// collides when panels report serial 0 — common for identical monitors).
enum EDID {

    /// A short hex hash of the EDID whose parsed vendor/product/serial match the
    /// given CoreGraphics numbers. nil when no matching EDID is found (e.g. the
    /// built-in, or displays behind adapters that don't expose one).
    static func hash(vendor: UInt32, product: UInt32, serial: UInt32) -> String? {
        for edid in allEDIDs() {
            let p = parse(edid)
            // CoreGraphics' vendor/product/serial come straight from the EDID header.
            // When they match, hash the *full* EDID — so two monitors with the same
            // v/p/s but any byte-level difference get distinct fingerprints. (Truly
            // byte-identical EDIDs remain indistinguishable; nothing can fix that.)
            if p.vendor == vendor && p.product == product && p.serial == serial {
                return djb2Hex(edid)
            }
        }
        return nil
    }

    /// The raw EDID bytes of every display in the IOKit registry. The old
    /// `IODisplayConnect` path is empty on modern macOS / Apple Silicon, so walk the
    /// whole registry for any service exposing an EDID property.
    private static func allEDIDs() -> [Data] {
        var result: [Data] = []
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            for key in ["IODisplayEDID", "EDID", "AppleDisplayEDID"] {
                if let data = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Data, data.count >= 128 {
                    result.append(data)
                    break
                }
            }
        }
        return result
    }

    /// Parse the EDID manufacturer id, product code, and serial.
    private static func parse(_ edid: Data) -> (vendor: UInt32, product: UInt32, serial: UInt32) {
        let b = [UInt8](edid)
        let mfg = (UInt32(b[8]) << 8) | UInt32(b[9])                    // bytes 8–9, big-endian
        let product = (UInt32(b[11]) << 8) | UInt32(b[10])             // bytes 10–11, little-endian
        let serial = UInt32(b[12]) | (UInt32(b[13]) << 8)              // bytes 12–15, little-endian
                   | (UInt32(b[14]) << 16) | (UInt32(b[15]) << 24)
        return (mfg, product, serial)
    }

    /// A compact, stable hex hash of the bytes (djb2 → 8 hex chars).
    private static func djb2Hex(_ data: Data) -> String {
        var h: UInt64 = 5381
        for byte in data { h = (h &* 33) &+ UInt64(byte) }
        return String(format: "%08x", UInt32(truncatingIfNeeded: h))
    }
}
