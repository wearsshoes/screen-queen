import CoreGraphics

enum MoveDirection {
    case up, down, left, right
    var isVertical: Bool { self == .up || self == .down }
}

enum VAnchor: Equatable { case top, center, bottom }
enum HAnchor: Equatable { case left, center, right }

/// A vertical alignment position for the selected display: a target `minY` plus
/// which anchors line up (for highlighting the alignment dots).
struct VSnap {
    let value: CGFloat
    let selfAnchor: VAnchor
    let otherAnchor: VAnchor
    let otherID: CGDirectDisplayID
}

struct HSnap {
    let value: CGFloat
    let selfAnchor: HAnchor
    let otherAnchor: HAnchor
    let otherID: CGDirectDisplayID
}

/// Alignment + edge snap targets shared by drag-snapping and keyboard alignment
/// cycling. All values are target *minimum* coordinates for the selected rect.
enum Snapping {

    /// The seven top/center/bottom alignments of the selected rect (height `h`)
    /// against each other display.
    static func verticalAligns(selectedHeight h: CGFloat, others: [DisplaySnapshot]) -> [VSnap] {
        var r: [VSnap] = []
        for o in others {
            let t = o.bounds.minY, m = o.bounds.midY, b = o.bounds.maxY
            r.append(VSnap(value: t - h / 2, selfAnchor: .center, otherAnchor: .top, otherID: o.id))
            r.append(VSnap(value: m,         selfAnchor: .top,    otherAnchor: .center, otherID: o.id))
            r.append(VSnap(value: t,         selfAnchor: .top,    otherAnchor: .top, otherID: o.id))
            r.append(VSnap(value: m - h / 2, selfAnchor: .center, otherAnchor: .center, otherID: o.id))
            r.append(VSnap(value: b - h,     selfAnchor: .bottom, otherAnchor: .bottom, otherID: o.id))
            r.append(VSnap(value: m - h,     selfAnchor: .bottom, otherAnchor: .center, otherID: o.id))
            r.append(VSnap(value: b - h / 2, selfAnchor: .center, otherAnchor: .bottom, otherID: o.id))
        }
        return r
    }

    static func horizontalAligns(selectedWidth w: CGFloat, others: [DisplaySnapshot]) -> [HSnap] {
        var r: [HSnap] = []
        for o in others {
            let l = o.bounds.minX, c = o.bounds.midX, rt = o.bounds.maxX
            r.append(HSnap(value: l - w / 2, selfAnchor: .center, otherAnchor: .left, otherID: o.id))
            r.append(HSnap(value: c,         selfAnchor: .left,   otherAnchor: .center, otherID: o.id))
            r.append(HSnap(value: l,         selfAnchor: .left,   otherAnchor: .left, otherID: o.id))
            r.append(HSnap(value: c - w / 2, selfAnchor: .center, otherAnchor: .center, otherID: o.id))
            r.append(HSnap(value: rt - w,    selfAnchor: .right,  otherAnchor: .right, otherID: o.id))
            r.append(HSnap(value: c - w,     selfAnchor: .right,  otherAnchor: .center, otherID: o.id))
            r.append(HSnap(value: rt - w / 2, selfAnchor: .center, otherAnchor: .right, otherID: o.id))
        }
        return r
    }

    /// Edge-dock targets so the dragged rect touches a neighbor's edge (these are
    /// adjacency, not alignment, so no anchor dots).
    static func horizontalEdges(selectedWidth w: CGFloat, others: [DisplaySnapshot]) -> [CGFloat] {
        others.flatMap { [$0.bounds.maxX, $0.bounds.minX - w] }
    }
    static func verticalEdges(selectedHeight h: CGFloat, others: [DisplaySnapshot]) -> [CGFloat] {
        others.flatMap { [$0.bounds.maxY, $0.bounds.minY - h] }
    }
}
