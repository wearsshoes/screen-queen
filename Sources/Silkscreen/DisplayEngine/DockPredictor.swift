import AppKit
import CoreGraphics

/// Predicts which display macOS will place the Dock on, for a given (possibly
/// uncommitted) point arrangement.
///
/// The Dock doesn't just go to the globally-extreme screen: it **flows from the main
/// display** toward the Dock's edge, hopping across the seams perpendicular to that
/// edge, and lands on the last screen it can reach. For a left Dock it walks *left*
/// through vertical seams (each step to a screen abutting the current one's left edge
/// with real vertical overlap); right Dock walks right; bottom Dock walks *down*
/// through horizontal seams. A screen that's leftmost overall but not reachable
/// leftward-from-main doesn't get the Dock.
enum DockPredictor {

    enum Edge { case bottom, left, right }

    /// The Dock's edge from its `orientation` preference (absent ⇒ bottom, the default).
    static func edge(defaults: UserDefaults = UserDefaults(suiteName: "com.apple.dock") ?? .standard) -> Edge {
        switch defaults.string(forKey: "orientation") {
        case "left": return .left
        case "right": return .right
        default: return .bottom
        }
    }

    /// The display the Dock lands on for `pointRects` (each display's point bounds):
    /// walk from `mainID` toward the Dock edge across abutting seams until no further
    /// step exists. nil if there's no main or no rects.
    static func dockDisplay(pointRects: [CGDirectDisplayID: CGRect],
                            mainID: CGDirectDisplayID?,
                            edge: Edge) -> CGDirectDisplayID? {
        guard let start = mainID ?? pointRects.keys.first, pointRects[start] != nil else { return nil }
        let tol: CGFloat = 2

        // Does `n` abut `cur` on the Dock-ward side, with real overlap along the seam?
        func stepsToward(from cur: CGRect, _ n: CGRect) -> Bool {
            switch edge {
            case .left:   // n is to cur's left: n.maxX ≈ cur.minX, vertical overlap
                return abs(n.maxX - cur.minX) <= tol && min(cur.maxY, n.maxY) - max(cur.minY, n.minY) > tol
            case .right:  // n to cur's right
                return abs(n.minX - cur.maxX) <= tol && min(cur.maxY, n.maxY) - max(cur.minY, n.minY) > tol
            case .bottom: // n below cur (CG y-down): n.minY ≈ cur.maxY, horizontal overlap
                return abs(n.minY - cur.maxY) <= tol && min(cur.maxX, n.maxX) - max(cur.minX, n.minX) > tol
            }
        }

        var current = start
        var visited: Set<CGDirectDisplayID> = [start]
        while true {
            let curRect = pointRects[current]!
            // Among unvisited neighbors on the Dock-ward side, take the one that reaches
            // furthest toward the edge (so parallel seams resolve to the extreme screen).
            let next = pointRects
                .filter { !visited.contains($0.key) && stepsToward(from: curRect, $0.value) }
                .min { edgeward($0.value, edge) < edgeward($1.value, edge) }
            guard let next else { return current }
            visited.insert(next.key)
            current = next.key
        }
    }

    /// How far toward the Dock edge a rect reaches (smaller = more Dock-ward), for
    /// picking among several valid next steps.
    private static func edgeward(_ r: CGRect, _ edge: Edge) -> CGFloat {
        switch edge {
        case .left:   return r.minX
        case .right:  return -r.maxX
        case .bottom: return -r.maxY   // CG y-down: larger maxY is lower/more Dock-ward
        }
    }
}
