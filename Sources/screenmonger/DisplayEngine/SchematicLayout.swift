import CoreGraphics

/// A reference bar at one seam: a window crossing it, keeping its **point** size
/// (`windowPoints`) across displays so its *physical* size changes by density
/// (`physLenInchesA/B`) — the size jump the arranger reveals. See `barGeometry` for
/// how the length and centers are placed.
struct SeamBar {
    let aID: CGDirectDisplayID   // left (vertical seam) / top (horizontal seam)
    let bID: CGDirectDisplayID   // right / bottom
    let isVertical: Bool
    let physLine: CGFloat        // physical seam coordinate
    let physAlongA: CGFloat      // bar center along the seam on a (physical)
    let physAlongB: CGFloat      // ditto on b
    let localAlongA: CGFloat     // bar center on a, as a point offset from a's leading edge
    let localAlongB: CGFloat     // ditto on b
    let windowPoints: CGFloat    // the window's point size (same on both screens)
    let physLenInchesA: CGFloat  // that window's physical length on a
    let physLenInchesB: CGFloat  // ditto on b (differs from a by density)
}

/// Translation between the macOS *point* arrangement and the *physical* schematic
/// (true relative sizes), shared by the arranger and the on-glass overlay.
///
/// `toPlane` interprets a committed layout (point → physical); `toPoints` converts
/// the plane back to commit (physical → point). A display's coordinate along a seam
/// maps piecewise-linearly through four anchors where the two metric spaces agree:
/// the two corners and the two edge-alignments.
enum SchematicLayout {

    /// Physical size in inches, falling back to a points/100 proxy when the
    /// physical size is unknown (so unsized displays still lay out sensibly).
    static func physSize(_ d: DisplaySnapshot) -> CGSize {
        let w = d.physicalSizeMM.width / 25.4, h = d.physicalSizeMM.height / 25.4
        if w > 1, h > 1 { return CGSize(width: w, height: h) }
        return CGSize(width: d.bounds.width / 100, height: d.bounds.height / 100)
    }

    // MARK: - Interpret: point → physical (the plane)

    /// Lay the committed point arrangement out on the physical plane: a BFS from
    /// the main display docks each display to its parent and places it along the
    /// seam via the seam map.
    static func toPlane(_ eff: [DisplaySnapshot]) -> [CGDirectDisplayID: CGRect] {
        guard !eff.isEmpty else { return [:] }
        let byID = Dictionary(uniqueKeysWithValues: eff.map { ($0.id, $0) })
        let start = eff.first(where: { $0.isMain }) ?? eff[0]
        var out: [CGDirectDisplayID: CGRect] = [start.id: CGRect(origin: .zero, size: physSize(start))]
        var queue = [start.id]
        let tol: CGFloat = 2

        while !queue.isEmpty {
            let parent = byID[queue.removeFirst()]!
            let pp = parent.bounds          // point bounds
            let pr = out[parent.id]!        // physical rect
            for child in eff where out[child.id] == nil {
                let c = child.bounds, cs = physSize(child)
                // Allow touching or corner-adjacent (overlap ≈ 0) so diagonal pairs connect.
                let yOv = min(pp.maxY, c.maxY) - max(pp.minY, c.minY)
                let xOv = min(pp.maxX, c.maxX) - max(pp.minX, c.minX)
                var r: CGRect?
                if abs(c.minX - pp.maxX) <= tol, yOv > -tol {
                    r = CGRect(x: pr.maxX, y: alignedPerp(child: child, parent: parent, pr, cs, vertical: true), width: cs.width, height: cs.height)
                } else if abs(c.maxX - pp.minX) <= tol, yOv > -tol {
                    r = CGRect(x: pr.minX - cs.width, y: alignedPerp(child: child, parent: parent, pr, cs, vertical: true), width: cs.width, height: cs.height)
                } else if abs(c.minY - pp.maxY) <= tol, xOv > -tol {
                    r = CGRect(x: alignedPerp(child: child, parent: parent, pr, cs, vertical: false), y: pr.maxY, width: cs.width, height: cs.height)
                } else if abs(c.maxY - pp.minY) <= tol, xOv > -tol {
                    r = CGRect(x: alignedPerp(child: child, parent: parent, pr, cs, vertical: false), y: pr.minY - cs.height, width: cs.width, height: cs.height)
                }
                if let r { out[child.id] = r; queue.append(child.id) }
            }
        }
        // Displays with no shared edge: place relative to the main at the main's density.
        if eff.contains(where: { out[$0.id] == nil }) {
            let mr = out[start.id]!
            let kx = mr.width / start.bounds.width, ky = mr.height / start.bounds.height
            for d in eff where out[d.id] == nil {
                out[d.id] = CGRect(x: mr.minX + (d.bounds.minX - start.bounds.minX) * kx,
                                   y: mr.minY + (d.bounds.minY - start.bounds.minY) * ky,
                                   width: physSize(d).width, height: physSize(d).height)
            }
        }
        return out
    }

    // MARK: - Commit: physical → point

    /// Inverse of `toPlane`: reconstruct a point arrangement from the physical plane
    /// `rects` and each display's point size. BFS from the main; each child docked to
    /// a placed parent gets its perpendicular point-flush and its along-seam point via
    /// the inverse seam map. The main lands at (0,0).
    static func toPoints(rects: [CGDirectDisplayID: CGRect],
                         displays: [DisplaySnapshot]) -> [CGDirectDisplayID: CGPoint] {
        guard !displays.isEmpty else { return [:] }
        let byID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        let start = displays.first(where: { $0.isMain }) ?? displays[0]
        guard rects[start.id] != nil else {
            return Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.bounds.origin) })
        }
        var origins: [CGDirectDisplayID: CGPoint] = [start.id: .zero]
        var queue = [start.id]
        let tol: CGFloat = 2

        while !queue.isEmpty {
            let parent = byID[queue.removeFirst()]!
            let pr = rects[parent.id]!                                   // parent physical
            let pp = CGRect(origin: origins[parent.id]!, size: parent.bounds.size) // parent point
            for child in displays where origins[child.id] == nil {
                guard let cr = rects[child.id] else { continue }
                let cs = child.bounds.size, cPhys = physSize(child)
                let yOv = min(pr.maxY, cr.maxY) - max(pr.minY, cr.minY)
                let xOv = min(pr.maxX, cr.maxX) - max(pr.minX, cr.minX)
                func along(_ physAlong: CGFloat, _ vertical: Bool) -> CGFloat {
                    seamPoint(physAlong, seamAnchors(child: child, cPhys, parentPoint: pp, parentPhys: pr, vertical: vertical))
                }
                var origin: CGPoint?
                if abs(cr.minX - pr.maxX) <= tol, yOv > -tol {
                    origin = CGPoint(x: pp.maxX, y: along(cr.minY, true))
                } else if abs(cr.maxX - pr.minX) <= tol, yOv > -tol {
                    origin = CGPoint(x: pp.minX - cs.width, y: along(cr.minY, true))
                } else if abs(cr.minY - pr.maxY) <= tol, xOv > -tol {
                    origin = CGPoint(x: along(cr.minX, false), y: pp.maxY)
                } else if abs(cr.maxY - pr.minY) <= tol, xOv > -tol {
                    origin = CGPoint(x: along(cr.minX, false), y: pp.minY - cs.height)
                }
                if let origin { origins[child.id] = origin; queue.append(child.id) }
            }
        }
        // Disconnected (e.g. Shift-dragged into a gap): place relative to the main
        // at the main's density.
        if let mr = rects[start.id] {
            let kx = start.bounds.width / max(mr.width, 0.01), ky = start.bounds.height / max(mr.height, 0.01)
            for d in displays where origins[d.id] == nil {
                let dr = rects[d.id] ?? CGRect(origin: .zero, size: physSize(d))
                origins[d.id] = CGPoint(x: (dr.minX - mr.minX) * kx, y: (dr.minY - mr.minY) * ky)
            }
        }
        return origins
    }

    /// The child's physical coordinate along the seam, from its point coordinate via
    /// the four seam anchors.
    private static func alignedPerp(child: DisplaySnapshot, parent: DisplaySnapshot,
                                    _ pr: CGRect, _ cs: CGSize, vertical: Bool) -> CGFloat {
        let anchors = seamAnchors(child: child, cs, parentPoint: parent.bounds, parentPhys: pr, vertical: vertical)
        return seamPhysical(vertical ? child.bounds.minY : child.bounds.minX, anchors)
    }

    /// Point-along → physical-along along a seam. The map can be non-monotonic (a
    /// taller-and-narrower neighbor), which is fine: interpret and commit only
    /// evaluate it *at* anchors, where it's exact.
    static func seamPhysical(_ pointAlong: CGFloat, _ anchors: [(CGFloat, CGFloat)]) -> CGFloat {
        piecewise(pointAlong, anchors)
    }

    /// The inverse (physical-along → point-along) used at commit.
    static func seamPoint(_ physAlong: CGFloat, _ anchors: [(CGFloat, CGFloat)]) -> CGFloat {
        piecewise(physAlong, anchors.map { ($0.1, $0.0) })
    }

    /// The four (point, physical) anchor pairs along the seam where the two metric
    /// spaces agree — two corners and the two edge-alignments.
    static func seamAnchors(child: DisplaySnapshot, _ cs: CGSize,
                            parentPoint pp: CGRect, parentPhys pr: CGRect,
                            vertical: Bool) -> [(CGFloat, CGFloat)] {
        let c = child.bounds
        return vertical
            ? [(pp.minY - c.height, pr.minY - cs.height), (pp.minY, pr.minY),
               (pp.maxY - c.height, pr.maxY - cs.height), (pp.maxY, pr.maxY)]
            : [(pp.minX - c.width, pr.minX - cs.width), (pp.minX, pr.minX),
               (pp.maxX - c.width, pr.maxX - cs.width), (pp.maxX, pr.maxX)]
    }

    /// Linear interpolation through `pts` (x → y), extrapolating with the end
    /// slopes outside the range. Ties in x (collapsed anchors) read as a jump.
    static func piecewise(_ x: CGFloat, _ pts: [(CGFloat, CGFloat)]) -> CGFloat {
        let p = pts.sorted { $0.0 < $1.0 }
        func lerp(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> CGFloat {
            guard b.0 != a.0 else { return (a.1 + b.1) / 2 } // vertical segment → midpoint
            return a.1 + (b.1 - a.1) / (b.0 - a.0) * (x - a.0)
        }
        if x <= p[0].0 { return lerp(p[0], p[1]) }
        for i in 0..<(p.count - 1) where x <= p[i + 1].0 { return lerp(p[i], p[i + 1]) }
        return lerp(p[p.count - 2], p[p.count - 1])
    }

    // MARK: - Physical snap targets (the seven anchor offsets)

    /// The seven alignment configs per seam, in spatial order (the selected
    /// display sliding from one extreme to the other along the shared edge).
    /// Index 3 is center↔center; (left,right)/(right,left) are intentionally
    /// absent (they'd pull the displays apart).
    static let hPairs: [(HAnchor, HAnchor)] = [
        (.center, .left), (.left, .left), (.right, .center), (.center, .center),
        (.left, .center), (.right, .right), (.center, .right)
    ]
    static let vPairs: [(VAnchor, VAnchor)] = [
        (.center, .top), (.top, .top), (.bottom, .center), (.center, .center),
        (.top, .center), (.bottom, .bottom), (.center, .bottom)
    ]

    static func frac(_ a: HAnchor) -> CGFloat { a == .left ? 0 : (a == .center ? 0.5 : 1) }
    static func frac(_ a: VAnchor) -> CGFloat { a == .top ? 0 : (a == .center ? 0.5 : 1) }

    /// The seven *physical* alignment positions along a horizontal seam: the child's
    /// `minX` that lands each child anchor on the parent's matching anchor, sorted by
    /// position (visual order) for cycling and drag-magnet targets.
    static func physSnapsH(childWidth cw: CGFloat, parent pr: CGRect) -> [(along: CGFloat, selfAnchor: HAnchor, otherAnchor: HAnchor)] {
        hPairs.map { (pr.minX + frac($0.1) * pr.width - frac($0.0) * cw, $0.0, $0.1) }
            .sorted { $0.0 < $1.0 }
    }

    static func physSnapsV(childHeight ch: CGFloat, parent pr: CGRect) -> [(along: CGFloat, selfAnchor: VAnchor, otherAnchor: VAnchor)] {
        vPairs.map { (pr.minY + frac($0.1) * pr.height - frac($0.0) * ch, $0.0, $0.1) }
            .sorted { $0.0 < $1.0 }
    }

    // MARK: - Reference bars

    static func seamBars(_ displays: [DisplaySnapshot],
                         rects: [CGDirectDisplayID: CGRect]) -> [SeamBar] {
        let tol: CGFloat = 1.5
        var out: [SeamBar] = []
        for i in 0..<displays.count {
            for j in (i + 1)..<displays.count {
                guard let ri = rects[displays[i].id], let rj = rects[displays[j].id] else { continue }

                // Vertical seam: one display's right edge meets the other's left.
                if abs(ri.maxX - rj.minX) <= tol || abs(rj.maxX - ri.minX) <= tol {
                    let leftIsI = abs(ri.maxX - rj.minX) <= tol
                    let aI = leftIsI ? i : j, bI = leftIsI ? j : i
                    let A = rects[displays[aI].id]!, B = rects[displays[bI].id]!
                    let lo = max(A.minY, B.minY), hi = min(A.maxY, B.maxY)
                    if hi - lo > tol {
                        out.append(makeBar(displays, aI, bI, A, B, vertical: true,
                                           line: A.maxX, lo: lo, hi: hi))
                    }
                }
                // Horizontal seam: one display's bottom edge meets the other's top.
                if abs(ri.maxY - rj.minY) <= tol || abs(rj.maxY - ri.minY) <= tol {
                    let topIsI = abs(ri.maxY - rj.minY) <= tol
                    let aI = topIsI ? i : j, bI = topIsI ? j : i
                    let A = rects[displays[aI].id]!, B = rects[displays[bI].id]!
                    let lo = max(A.minX, B.minX), hi = min(A.maxX, B.maxX)
                    if hi - lo > tol {
                        out.append(makeBar(displays, aI, bI, A, B, vertical: false,
                                           line: A.maxY, lo: lo, hi: hi))
                    }
                }
            }
        }
        return out
    }

    private static func makeBar(_ displays: [DisplaySnapshot],
                                _ aI: Int, _ bI: Int, _ ra: CGRect, _ rb: CGRect,
                                vertical: Bool, line: CGFloat, lo: CGFloat, hi: CGFloat) -> SeamBar {
        let a = displays[aI], b = displays[bI]
        // Points-per-inch along the seam axis (width for a horizontal seam).
        let aPPI = vertical ? a.bounds.height / max(ra.height, 0.01) : a.bounds.width / max(ra.width, 0.01)
        let bPPI = vertical ? b.bounds.height / max(rb.height, 0.01) : b.bounds.width / max(rb.width, 0.01)

        // The smaller screen owns the window; the bigger renders the same window at
        // its own density. Solve the geometry in the smaller screen's frame.
        let aSmaller = (vertical ? ra.height : ra.width) <= (vertical ? rb.height : rb.width)
        let sr = aSmaller ? ra : rb, big = aSmaller ? rb : ra
        let sPPI = aSmaller ? aPPI : bPPI, bigPPI = aSmaller ? bPPI : aPPI
        func span(_ r: CGRect) -> (lo: CGFloat, hi: CGFloat) {
            vertical ? (r.minY, r.maxY) : (r.minX, r.maxX)
        }
        let g = barGeometry(small: span(sr), big: span(big), sPPI: sPPI, bigPPI: bigPPI)

        let windowPoints = g.length * sPPI
        let alongA = aSmaller ? g.smallCenter : g.bigCenter
        let alongB = aSmaller ? g.bigCenter : g.smallCenter

        return SeamBar(
            aID: a.id, bID: b.id, isVertical: vertical,
            physLine: line, physAlongA: alongA, physAlongB: alongB,
            localAlongA: localAlong(alongA, physRect: ra, pointSize: a.bounds.size, vertical: vertical),
            localAlongB: localAlong(alongB, physRect: rb, pointSize: b.bounds.size, vertical: vertical),
            windowPoints: windowPoints,
            physLenInchesA: windowPoints / aPPI, physLenInchesB: windowPoints / bPPI
        )
    }

    /// The 1-D window model along the seam axis, in the smaller screen's frame:
    /// returns the smaller bar's length and both bars' centers (physical). While the
    /// smaller screen is within the neighbor the window is a constant full-edge size;
    /// past that the screens overhang and it shrinks to the overlap.
    static func barGeometry(small s: (lo: CGFloat, hi: CGFloat),
                            big b: (lo: CGFloat, hi: CGFloat),
                            sPPI: CGFloat, bigPPI: CGFloat)
        -> (length: CGFloat, smallCenter: CGFloat, bigCenter: CGFloat) {
        let sEdge = s.hi - s.lo, bEdge = b.hi - b.lo
        let bigLen = sEdge * sPPI / max(bigPPI, 0.01)   // the full window on the bigger screen

        if s.lo >= b.lo && s.hi <= b.hi {
            let slack = bEdge - sEdge                    // travel before the smaller screen overhangs
            let f = slack > 0 ? (s.lo - b.lo) / slack : 0.5
            // Both bars at fraction f of their travel, so the bigger reaches its edge
            // exactly at edge-alignment (f = 0 or 1).
            return (sEdge, s.lo + sEdge / 2, b.lo + bigLen / 2 + f * (bEdge - bigLen))
        } else {
            let ov0 = max(s.lo, b.lo), ov1 = min(s.hi, b.hi)
            let len = max(0, ov1 - ov0)
            let overhangHigh = s.hi > b.hi               // smaller screen pokes past the high edge
            let pin = overhangHigh ? ov1 : ov0           // the still-shared edge
            let bigHalf = len * sPPI / max(bigPPI, 0.01) / 2
            return overhangHigh ? (len, pin - len / 2, pin - bigHalf)
                                : (len, pin + len / 2, pin + bigHalf)
        }
    }

    /// The bar center as a point offset from the display's own leading edge (top for
    /// a vertical seam, left for a horizontal one). Screen-local, so it's independent
    /// of the global point origin — the two screens' bars counter-slide correctly
    /// regardless of any re-rooting.
    private static func localAlong(_ phys: CGFloat, physRect: CGRect,
                                   pointSize: CGSize, vertical: Bool) -> CGFloat {
        if vertical {
            guard physRect.height > 0 else { return pointSize.height / 2 }
            return (phys - physRect.minY) / physRect.height * pointSize.height
        } else {
            guard physRect.width > 0 else { return pointSize.width / 2 }
            return (phys - physRect.minX) / physRect.width * pointSize.width
        }
    }
}
