import CoreGraphics

/// The arranger's pure view geometry: the plane↔view transform, the fit that chooses
/// it, and the chrome/ghost/pixel mappings that ride it. Framework-free (CoreGraphics
/// types only) so any rendering layer — the AppKit canvas today, a SwiftUI Canvas
/// tomorrow — shares one set of coordinates, verified by one set of tests.
enum ArrangerGeometry {

    // MARK: - The plane↔view transform

    struct Transform {
        let scale: CGFloat            // view px per plane inch
        let offset: CGPoint
        let unionOrigin: CGPoint

        // The physical plane is y-down (top-left origin, from `CGDisplayBounds`), and so
        // is the view (the Arranger NSView is flipped, like SwiftUI's Canvas and gesture
        // space) — one shared orientation, no flip anywhere.
        func viewRect(_ r: CGRect) -> CGRect {
            CGRect(x: offset.x + (r.minX - unionOrigin.x) * scale,
                   y: offset.y + (r.minY - unionOrigin.y) * scale,
                   width: r.width * scale, height: r.height * scale)
        }
        func viewPoint(_ g: CGPoint) -> CGPoint {
            CGPoint(x: offset.x + (g.x - unionOrigin.x) * scale,
                    y: offset.y + (g.y - unionOrigin.y) * scale)
        }
        /// Inverse of `viewPoint` (a pure scale + translate, so the round-trip is exact).
        func planePoint(_ v: CGPoint) -> CGPoint {
            CGPoint(x: (v.x - offset.x) / scale + unionOrigin.x,
                    y: (v.y - offset.y) / scale + unionOrigin.y)
        }
    }

    /// Fit the physical plane into a view: the union of tiles centered at the view
    /// midpoint, zoomed so three of the physically-largest display fit across the view
    /// (matching axes), capped so the union never overflows the padding.
    static func fit(_ rects: [CGDirectDisplayID: CGRect], in bounds: CGRect,
                    padding: CGFloat) -> Transform? {
        let values = Array(rects.values)
        guard let first = values.first else { return nil }
        let union = values.dropFirst().reduce(first) { $0.union($1) }
        guard union.width > 0, union.height > 0 else { return nil }

        // Center the whole arrangement at the view midpoint — the same layout on every
        // screen, rather than pivoting each canvas around its own tile.
        let focus = CGPoint(x: union.midX, y: union.midY)

        let availW = bounds.width - padding * 2, availH = bounds.height - padding * 2

        // Target zoom: three of the physically-largest display fit across the view,
        // matching axes, so a landscape screen isn't over-shrunk by its height.
        let largestW = rects.values.map(\.width).max() ?? union.width
        let largestH = rects.values.map(\.height).max() ?? union.height
        let targetScale = min(availW / (3 * max(largestW, 0.0001)),
                              availH / (3 * max(largestH, 0.0001)))

        // But never overflow: cap so the union fits with padding.
        let reachX = max(focus.x - union.minX, union.maxX - focus.x)
        let reachY = max(focus.y - union.minY, union.maxY - focus.y)
        let fitScale = min(availW / 2 / max(reachX, 0.0001), availH / 2 / max(reachY, 0.0001))
        let scale = min(targetScale, fitScale)

        let offset = CGPoint(x: bounds.midX - (focus.x - union.minX) * scale,
                             y: bounds.midY - (focus.y - union.minY) * scale)
        return Transform(scale: scale, offset: offset, unionOrigin: union.origin)
    }

    // MARK: - Chrome placement

    /// A map-relative chrome rect: `size` already final, centre at
    /// `bounds.mid + offset × scale` where the offset is in **plane inches**.
    static func chromeViewRect(finalSize size: CGSize, centreOffsetInches off: CGPoint,
                               bounds: CGRect, scale: CGFloat) -> CGRect {
        let centre = CGPoint(x: bounds.midX + off.x * scale,
                             y: bounds.midY + off.y * scale)
        return CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    // MARK: - Ghost mapping (active canvas's view coords → another canvas's)

    /// Map a point's offset from the active canvas's centre onto the destination
    /// canvas, scaled by the ratio of the two minimap scales. Identity when
    /// `ghostScale == 1` and the centres coincide.
    static func ghostPoint(_ p: CGPoint, ghostScale: CGFloat,
                           activeCenter: CGPoint, destCenter: CGPoint) -> CGPoint {
        CGPoint(x: destCenter.x + ghostScale * (p.x - activeCenter.x),
                y: destCenter.y + ghostScale * (p.y - activeCenter.y))
    }

    // MARK: - Cursor → plane

    /// Map a global cursor point onto the physical plane: its fraction within the
    /// display's point bounds transfers to the display's plane rect. Both spaces are
    /// y-down, like everything else.
    static func planePoint(cursor: CGPoint, displayBounds: CGRect,
                           planeRect: CGRect) -> CGPoint? {
        guard displayBounds.width > 0, displayBounds.height > 0 else { return nil }
        let fx = (cursor.x - displayBounds.minX) / displayBounds.width
        let fy = (cursor.y - displayBounds.minY) / displayBounds.height
        return CGPoint(x: planeRect.minX + fx * planeRect.width,
                       y: planeRect.minY + fy * planeRect.height)
    }

    // MARK: - Pixel snapping

    /// Round to the nearest whole *device* pixel — a fractional origin smears content
    /// across pixel boundaries.
    static func pixelSnap(_ v: CGFloat, backingScale: CGFloat) -> CGFloat {
        (v * backingScale).rounded() / backingScale
    }
}
