import SwiftUI

/// A seamstress's measuring tape hugging the seam: a soft cream ribbon ruled in
/// inches along one edge (down to eighths) and centimeters along the other —
/// dual-scale, like every tailor's tape since forever — with a small metal crimp
/// tab at each end. The honest tape is ruled at the reference's true pitch; the
/// liar's at her EDID-claimed pitch, so a physical match reads as two different
/// numbers. Drag either tab to let tape out or take it in; grab the ribbon
/// anywhere to slide the whole thing along the seam; arrow keys nudge the length
/// for the final millimeter. Chalk lines (pink for x tapes, yellow for y) struck perpendicular from both
/// ends let the two tapes be sighted across the gap. The only label is the unit
/// printed over the ribbon — "inches" on the trusted tape, her "inches" on the
/// one being measured. Reports its live length so the controller can infer the
/// target's PPI. Purely an affordance — the readout and Save/Cancel live in the
/// floating panel.
///
/// `Tape` is the model + CoreGraphics draw pass (y-up, run under the Stage shim);
/// `TapeHost` is the hosting view that owns input (hit-carving so two overlapping
/// tapes share a window, drag classification, cursor rects, arrow keys).
///
/// The tape-local space stays y-up deliberately (unlike the rest of the app):
/// the "along" axis with zero at the inseam end is what keeps the grab/interval
/// math orientation-uniform; TapeHost is the one flip boundary.
@MainActor
final class Tape {
    var onResize: ((CGFloat) -> Void)?
    /// ⏎ pressed while this tape has keys: save the calibration.
    var onCommit: (() -> Void)?
    /// ⎋ pressed while this tape has keys: cancel out.
    var onCancel: (() -> Void)?
    /// The perpendicular tape sharing this screen: its length is echoed onto this
    /// tape in its chalk color (see `drawChalk`), and linked resizes arrive from
    /// it via the controller.
    weak var partner: Tape?

    /// Host wiring (set by TapeHost): repaint, fade on invalid, cursor-rect refresh.
    var onNeedsRepaint: (() -> Void)?
    var onInvalidChanged: ((Bool) -> Void)?
    var onGrabRectsChanged: (() -> Void)?

    /// The host view's size (orientation-free, so no flip questions).
    var bounds: CGRect = .zero

    /// Whether arrow keys would land here right now, per the host's key/responder
    /// status — drives the far-tip glow.
    var keyboardIsLive: Bool = false {
        didSet { if keyboardIsLive != oldValue { onNeedsRepaint?() } }
    }

    /// A linked resize pushed this tape past its screen edge — it can't be
    /// trusted for measuring until the pair shrinks back. Shown, but faded.
    private(set) var isInvalid = false {
        didSet { if isInvalid != oldValue { onInvalidChanged?(isInvalid) } }
    }

    private var length: CGFloat
    private var offset: CGFloat = 0        // slide of the bar's center along the seam
    let anchor: BarPlacement
    /// Tick pitch in points: the reference's true points-per-inch on the honest
    /// tape, but the *EDID-claimed* pitch on the liar's — so at a physical match
    /// the two ribbons read different numbers. Her inches, as told by her.
    private let pointsPerInch: CGFloat
    /// Printed over the ribbon's midpoint — "inches" on the trusted tape, her
    /// "inches" on the one still being measured. This is how the tapes are told
    /// apart; there are no other labels.
    private let unitLabel: String
    /// Brand lettering on the ribbon: the trusted tape wears the house brand, the
    /// liar's wears something appropriately off-brand.
    private let brand: String
    private let finePrint: String
    private let palette: Palette

    /// Everything that differs between the honest tape and the vanity knockoff.
    /// Same ribbon, same rules — different boutique.
    struct Palette {
        let ribbon: NSColor      // the ribbon's base color
        let edge: NSColor        // the ribbon's outline
        let ink: NSColor         // inch scale and numbers
        let accent: NSColor      // cm scale and numbers
        let stitch: NSColor      // the dashed stitch lines
        let brandColor: NSColor
        let finePrintColor: NSColor
        let tipLight: NSColor    // crimp-tab metal gradient
        let tipDark: NSColor
        let crest: String        // printed beside the brand

        /// Warm cream vinyl, black-ish ink, red metric, silver tips — a tape that's
        /// lived an honest life in a sewing box.
        static let honest = Palette(
            ribbon: NSColor(calibratedRed: 0.99, green: 0.97, blue: 0.91, alpha: 0.97),
            edge: NSColor(calibratedRed: 0.45, green: 0.4, blue: 0.3, alpha: 0.5),
            ink: NSColor(calibratedRed: 0.15, green: 0.12, blue: 0.1, alpha: 1),
            accent: NSColor(calibratedRed: 0.75, green: 0.15, blue: 0.15, alpha: 1),
            stitch: NSColor(calibratedRed: 0.75, green: 0.65, blue: 0.5, alpha: 0.6),
            brandColor: .systemOrange,
            finePrintColor: NSColor(calibratedRed: 0.35, green: 0.3, blue: 0.25, alpha: 1),
            tipLight: NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1),
            tipDark: NSColor(calibratedRed: 0.6, green: 0.62, blue: 0.66, alpha: 1),
            crest: "👑")

        /// Royal purple satin, everything printed in gold, rose-gold tips,
        /// kiss-mark crest — the tape she bought herself. It flatters. That's
        /// its job.
        static let vanity = Palette(
            ribbon: NSColor(calibratedRed: 0.34, green: 0.12, blue: 0.58, alpha: 0.97),
            edge: NSColor(calibratedRed: 0.17, green: 0.05, blue: 0.32, alpha: 0.6),
            ink: NSColor(calibratedRed: 0.96, green: 0.8, blue: 0.38, alpha: 1),
            accent: NSColor(calibratedRed: 0.85, green: 0.66, blue: 0.28, alpha: 1),
            stitch: NSColor(calibratedRed: 0.9, green: 0.74, blue: 0.4, alpha: 0.7),
            brandColor: NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.45, alpha: 1),
            finePrintColor: NSColor(calibratedRed: 0.88, green: 0.72, blue: 0.42, alpha: 1),
            tipLight: NSColor(calibratedRed: 0.98, green: 0.8, blue: 0.74, alpha: 1),
            tipDark: NSColor(calibratedRed: 0.78, green: 0.5, blue: 0.44, alpha: 1),
            crest: "💋")
    }
    /// Ribbon cross-thickness — a tailor's 5/8" ribbon, scaled up enough to read.
    static let thickness: CGFloat = 26
    /// Shortest the tape folds down to.
    private static let minLength: CGFloat = 60
    /// The metal crimp tab at each end: its reach along the ribbon.
    private static let tipAlong: CGFloat = 13

    init(length: CGFloat, anchor: BarPlacement, pointsPerInch: CGFloat, unitLabel: String,
         brand: String, finePrint: String, palette: Palette) {
        self.length = length; self.anchor = anchor
        self.pointsPerInch = pointsPerInch; self.unitLabel = unitLabel
        self.brand = brand; self.finePrint = finePrint; self.palette = palette
    }

    var lengthIsVertical: Bool { anchor.lengthIsVertical }

    /// The bar's anchored center along the seam (before `offset`).
    private func anchorAlong() -> CGFloat { anchor.along }

    func rect() -> NSRect {
        CalibrationMath.barRect(length: length, offset: offset, thickness: Self.thickness, anchor: anchor, in: bounds)
    }

    /// Along-axis view coordinate of a point.
    private func along(_ p: CGPoint) -> CGFloat { lengthIsVertical ? p.y : p.x }
    private var maxAlong: CGFloat { lengthIsVertical ? bounds.height : bounds.width }

    /// Grab regions in (y-up) view coordinates: a metal tab at each end (drag to let
    /// tape out or take it in) and the ribbon between them (slide the whole tape).
    func grabRects(_ r: NSRect) -> (lowTip: NSRect, highTip: NSRect, ribbon: NSRect) {
        let tipSpan = Self.tipAlong + 28      // the tab plus a forgiving halo
        let tipCross = Self.thickness + 30
        if lengthIsVertical {
            let low = NSRect(x: r.midX - tipCross / 2, y: r.minY - 14, width: tipCross, height: tipSpan)
            let high = NSRect(x: r.midX - tipCross / 2, y: r.maxY - tipSpan + 14, width: tipCross, height: tipSpan)
            let ribbon = NSRect(x: r.minX - 10, y: low.maxY,
                                width: r.width + 20, height: max(high.minY - low.maxY, 0))
            return (low, high, ribbon)
        }
        let low = NSRect(x: r.minX - 14, y: r.midY - tipCross / 2, width: tipSpan, height: tipCross)
        let high = NSRect(x: r.maxX - tipSpan + 14, y: r.midY - tipCross / 2, width: tipSpan, height: tipCross)
        let ribbon = NSRect(x: low.maxX, y: r.minY - 10,
                            width: max(high.minX - low.maxX, 0), height: r.height + 20)
        return (low, high, ribbon)
    }

    // MARK: Grabs — the end tabs let tape out/in; the ribbon slides it

    enum Grab { case none, lowTip, highTip, slide }
    private(set) var grab: Grab = .none
    private var grabDelta: CGFloat = 0   // where in the grabbed part the drag started

    /// Classify a press at `p` (y-up). Returns whether this tape claimed it.
    @discardableResult
    func beginGrab(at p: CGPoint) -> Bool {
        let r = rect()
        let (lowR, highR, ribbonR) = grabRects(r)
        let start = lengthIsVertical ? r.minY : r.minX
        if highR.contains(p) {
            grab = .highTip; grabDelta = along(p) - (start + length)
        } else if lowR.contains(p) {
            grab = .lowTip; grabDelta = along(p) - start
        } else if ribbonR.contains(p) {
            grab = .slide; grabDelta = along(p) - (start + length / 2)
        } else {
            grab = .none
        }
        if grab != .none { onNeedsRepaint?() }
        return grab != .none
    }

    func moveGrab(to p: CGPoint) {
        guard grab != .none else { return }
        apply(p)
    }

    func endGrab() {
        grab = .none
        onNeedsRepaint?()
    }

    /// Whether `p` (y-up) lands on any grab region — the host's hit-carving.
    func claims(_ p: CGPoint) -> Bool {
        let (lowR, highR, ribbonR) = grabRects(rect())
        return lowR.contains(p) || highR.contains(p) || ribbonR.contains(p)
    }

    /// Adopt the length a linked resize implies (the partner was dragged; the
    /// pair keeps the screen's aspect ratio). Never clamps and keeps the center
    /// put — a length that no longer fits the screen instead marks the tape
    /// invalid, faded until the pair shrinks back. Does NOT fire `onResize`, so
    /// the sync can't ping-pong.
    func setLength(_ newLength: CGFloat) {
        guard abs(newLength - length) > 0.01 else { return }
        length = newLength
        let start = anchorAlong() + offset - length / 2
        isInvalid = start < -0.5 || start + length > maxAlong + 0.5
        onGrabRectsChanged?()
        onNeedsRepaint?()
    }

    private func apply(_ p: CGPoint) {
        let a = along(p)
        var start = anchorAlong() + offset - length / 2
        var end = start + length
        switch grab {
        case .lowTip:
            start = min(max(a - grabDelta, 0), end - Self.minLength)
        case .highTip:
            end = max(min(a - grabDelta, maxAlong), start + Self.minLength)
        case .slide:
            let c = min(max(a - grabDelta, length / 2), maxAlong - length / 2)
            start = c - length / 2; end = c + length / 2
        case .none:
            return
        }
        commit(start: start, end: end)
    }

    private func commit(start: CGFloat, end: CGFloat) {
        length = end - start
        offset = (start + end) / 2 - anchorAlong()
        isInvalid = start < -0.5 || end > maxAlong + 0.5   // direct drags re-legitimize
        onResize?(length)
        onGrabRectsChanged?()
        onNeedsRepaint?()
        partner?.onNeedsRepaint?()   // its echo of this length just moved
    }

    // MARK: Keyboard — dragging is coarse exactly at the scale that matters

    /// Handle a key press (already routed here by the host). True = consumed.
    func handleKey(code: UInt16, shift: Bool) -> Bool {
        let step: CGFloat = shift ? 10 : 1
        switch code {
        case 124, 126: nudge(step)     // → / ↑
        case 123, 125: nudge(-step)    // ← / ↓
        case 36, 76: onCommit?()       // ⏎ / keypad enter
        case 53: onCancel?()           // ⎋
        default: return false
        }
        return true
    }

    /// Let tape out (+) or take it in (−) by `delta` points at the far end. When
    /// that end is already at the screen edge, the near end gives instead.
    func nudge(_ delta: CGFloat) {
        var start = anchorAlong() + offset - length / 2
        var end = start + length
        let grown = end + delta
        if grown > maxAlong {
            end = maxAlong
            start = min(max(start - (grown - maxAlong), 0), end - Self.minLength)
        } else {
            end = max(grown, start + Self.minLength)
        }
        commit(start: start, end: end)
    }

    // MARK: Draw (y-up CoreGraphics, run under the Stage shim)

    func draw() {
        // (The soft scrim lives on the window — two sibling tapes shouldn't each
        // darken the screen again.)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = rect()

        // Draw everything in the ribbon's own space — origin at the zero end of the
        // ribbon's bottom edge, +x running out along the tape — so every graduation
        // and all the lettering stays parallel to the direction of travel. Vertical
        // seams rotate the whole tape 90°, zero at the bottom, like measuring an
        // inseam up from the floor.
        ctx.saveGState()
        ctx.translateBy(x: r.midX, y: r.midY)
        if lengthIsVertical { ctx.rotate(by: .pi / 2) }
        ctx.translateBy(x: -length / 2, y: -Self.thickness / 2)

        drawChalk()
        drawRibbon()
        drawBrand()
        drawRuler()
        drawTips()
        drawUnitLabel()
        ctx.restoreGState()
    }

    /// Which side of the blade faces the screen's center, in local space: +1 means
    /// local +y (above the blade), −1 below. The unit label goes on that side so it
    /// never crowds the screen edge the tape hugs.
    private var centerSide: CGFloat {
        switch anchor.edge {
        case .bottom, .right: return 1
        case .top, .left: return -1
        }
    }

    /// Two axes, two sticks of tailor's chalk: yellow for x, pink for y.
    private static let xChalk = NSColor(calibratedRed: 1.0, green: 0.86, blue: 0.25, alpha: 1)
    private static let yChalk = NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.66, alpha: 1)

    /// This tape's own chalk: yellow when it measures x, pink when it measures y.
    var chalkColor: NSColor { lengthIsVertical ? Self.yChalk : Self.xChalk }

    /// Tailor's chalk lines struck perpendicular from both ends of the ribbon,
    /// all the way across the screen — she marks before she cuts. Does what the
    /// laser level would, but this is an atelier. Layered dashed passes fake the
    /// grain of a struck line; the thin final pass keeps a crisp core to
    /// actually sight against.
    private func drawChalk() {
        let reach = max(bounds.width, bounds.height) * 2
        let chalk = chalkColor
        let passes: [(width: CGFloat, alpha: CGFloat, dash: [CGFloat], phase: CGFloat)] = [
            (9,   0.10, [],     0),   // powder halo
            (3.4, 0.28, [9, 3], 0),   // grain
            (2.2, 0.32, [4, 5], 6),   // more grain, out of phase
            (1.1, 0.85, [],     0),   // the crisp line she actually struck
        ]
        for x in [CGFloat(0), length] {
            for pass in passes {
                let line = NSBezierPath()
                line.move(to: CGPoint(x: x, y: -reach)); line.line(to: CGPoint(x: x, y: reach))
                line.lineWidth = pass.width
                if !pass.dash.isEmpty { line.setLineDash(pass.dash, count: pass.dash.count, phase: pass.phase) }
                chalk.withAlphaComponent(pass.alpha).setStroke()
                line.stroke()
            }
        }

        // The partner's length echoed onto this tape: a dashed pair in the
        // *partner's* chalk color, centered on this tape's middle — outside the
        // ends on the shorter tape, inside them on the longer (the linked pair
        // keeps the screen's aspect ratio, so the offset IS that ratio). Turn a
        // screen sideways and there's still a matching-colored line to sight
        // against the other display's solid chalk.
        if let partner {
            let ghost = NSBezierPath()
            for x in [length / 2 - partner.length / 2, length / 2 + partner.length / 2] {
                ghost.move(to: CGPoint(x: x, y: -reach)); ghost.line(to: CGPoint(x: x, y: reach))
            }
            ghost.lineWidth = 1.1
            ghost.setLineDash([7, 9], count: 2, phase: 0)
            partner.chalkColor.withAlphaComponent(0.6).setStroke()
            ghost.stroke()
        }
    }

    /// The ribbon: warm cream vinyl, gently shaded at the edges so it reads as a
    /// soft flat tape rather than a steel blade, with a faint stitch line along
    /// each edge because someone in the atelier insisted.
    private func drawRibbon() {
        let base = palette.ribbon
        let ribbon = NSRect(x: 0, y: 0, width: length, height: Self.thickness)
        let path = NSBezierPath(roundedRect: ribbon, xRadius: 3.5, yRadius: 3.5)
        NSGradient(colors: [
            base.blended(withFraction: 0.12, of: .black) ?? base,
            base,
            base,
            base.blended(withFraction: 0.10, of: .black) ?? base,
        ])?.draw(in: path, angle: 90)
        palette.edge.setStroke()
        path.lineWidth = 1; path.stroke()

        // Stitch lines: dashed, just inside each long edge.
        let stitch = NSBezierPath(); stitch.lineWidth = 0.7
        stitch.setLineDash([3, 2.5], count: 2, phase: 0)
        stitch.move(to: CGPoint(x: 3, y: 2.2)); stitch.line(to: CGPoint(x: length - 3, y: 2.2))
        stitch.move(to: CGPoint(x: 3, y: Self.thickness - 2.2))
        stitch.line(to: CGPoint(x: length - 3, y: Self.thickness - 2.2))
        palette.stitch.setStroke()
        stitch.stroke()
    }

    /// The printed rule, dual-scale like every tailor's tape: inches along the top
    /// edge (down to eighths) with an upright number at each one, centimeters along
    /// the bottom with a little red number every five. Nobody asked for the metric
    /// side. She provides regardless.
    private func drawRuler() {
        guard pointsPerInch > 8 else { return }
        let ink = palette.ink
        let red = palette.accent

        // Inch graduations hanging from the top edge; skip eighths if too coarse.
        let eighth = pointsPerInch / 8
        let step = eighth >= 3.5 ? 1 : 2
        let ticks = NSBezierPath(); ticks.lineWidth = 1
        var i = step
        while CGFloat(i) * eighth < length - 1 {
            let x = CGFloat(i) * eighth
            let drop: CGFloat
            if i % 8 == 0      { drop = Self.thickness * 0.46 }   // inch
            else if i % 4 == 0 { drop = Self.thickness * 0.32 }   // half
            else if i % 2 == 0 { drop = Self.thickness * 0.24 }   // quarter
            else               { drop = Self.thickness * 0.15 }   // eighth
            ticks.move(to: CGPoint(x: x, y: Self.thickness - 3))
            ticks.line(to: CGPoint(x: x, y: Self.thickness - 3 - drop))
            i += step
        }
        ink.withAlphaComponent(0.8).setStroke(); ticks.stroke()

        // Inch numbers, tucked under their graduation.
        let wholeInches = Int(length / pointsPerInch)
        if wholeInches >= 1 {
            for n in 1...wholeInches {
                let str = NSAttributedString(string: "\(n)", attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: ink,
                ])
                str.draw(at: CGPoint(x: CGFloat(n) * pointsPerInch + 2.5, y: Self.thickness * 0.28))
            }
        }

        // Centimeter graduations rising from the bottom edge, halves included.
        let cm = pointsPerInch / 2.54
        let cmTicks = NSBezierPath(); cmTicks.lineWidth = 0.8
        var j = 1
        while CGFloat(j) * (cm / 2) < length - 1 {
            let x = CGFloat(j) * (cm / 2)
            let rise = Self.thickness * (j % 2 == 0 ? 0.22 : 0.12)
            cmTicks.move(to: CGPoint(x: x, y: 3))
            cmTicks.line(to: CGPoint(x: x, y: 3 + rise))
            j += 1
        }
        red.withAlphaComponent(0.75).setStroke(); cmTicks.stroke()

        // A tiny red number every 5 cm.
        var k = 5
        while CGFloat(k) * cm < length - 1 {
            NSAttributedString(string: "\(k)", attributes: [
                .font: NSFont.systemFont(ofSize: 5.5, weight: .bold),
                .foregroundColor: red,
            ]).draw(at: CGPoint(x: CGFloat(k) * cm + 1.5, y: 3.5))
            k += 5
        }
    }

    /// Ribbon lettering after the first inch: her crest, the brand, and the
    /// compliance fine print. None of it is necessary. That is the point.
    private func drawBrand() {
        guard length > pointsPerInch * 3.2 else { return }
        let x = pointsPerInch * 1.18
        let crest = NSAttributedString(string: palette.crest, attributes: [.font: NSFont.systemFont(ofSize: 8)])
        crest.draw(at: CGPoint(x: x - 13, y: Self.thickness * 0.34))
        NSAttributedString(string: brand, attributes: [
            .font: NSFont.systemFont(ofSize: 7, weight: .black),
            .foregroundColor: palette.brandColor,
        ]).draw(at: CGPoint(x: x, y: Self.thickness * 0.36))
        NSAttributedString(string: finePrint, attributes: [
            .font: NSFont.systemFont(ofSize: 4.5, weight: .semibold),
            .foregroundColor: palette.finePrintColor,
        ]).draw(at: CGPoint(x: x, y: Self.thickness * 0.36 - 6))
    }

    /// The metal crimp tab at each end of the ribbon — folded metal, two crimp
    /// teeth, and a hang hole at each end for sewing-box nails it will never
    /// see. The tab that would move right now — the one being dragged, or the
    /// far tip while arrow keys are live — wears a glow in the tape's chalk color.
    private func drawTips() {
        let metal = NSGradient(colors: [palette.tipLight, palette.tipDark])
        let metalEdge = palette.tipDark.blended(withFraction: 0.5, of: .black) ?? palette.tipDark

        // Which end to spotlight: whichever tab is mid-drag, else the far tip
        // when arrow keys would land here. nil = no glow.
        let glowZeroEnd: Bool? = switch grab {
        case .lowTip: true
        case .highTip: false
        case .none, .slide: keyboardIsLive ? false : nil
        }

        for (x0, isZeroEnd) in [(-1.5, true), (length - Self.tipAlong + 1.5, false)] {
            // The tab barely overhangs the ribbon's edges — crimped metal sits
            // nearly flush, it doesn't wear shoulder pads.
            let tab = NSRect(x: x0, y: -1, width: Self.tipAlong, height: Self.thickness + 2)
            // Rounded only at the outer end; the tape-facing edge is a square
            // crimp, the way folded metal actually bites a ribbon.
            let path = tipPath(tab, roundedEndIsMax: !isZeroEnd)

            if glowZeroEnd == isZeroEnd {
                // Halo in this tape's chalk color, widening and fading outward.
                let glow = chalkColor
                for (inset, alpha, width): (CGFloat, CGFloat, CGFloat) in [(-2, 0.55, 2), (-5, 0.28, 3), (-8, 0.12, 4)] {
                    let halo = NSBezierPath(roundedRect: tab.insetBy(dx: inset, dy: inset),
                                            xRadius: 2.5 - inset, yRadius: 2.5 - inset)
                    glow.withAlphaComponent(alpha).setStroke(); halo.lineWidth = width; halo.stroke()
                }
            }

            metal?.draw(in: path, angle: 90)
            metalEdge.withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1; path.stroke()

            // The crimp teeth: two lines where the metal folds over the ribbon.
            let crimpX = isZeroEnd ? tab.maxX - 3 : tab.minX + 3
            let crimp = NSBezierPath(); crimp.lineWidth = 0.8
            crimp.move(to: CGPoint(x: crimpX, y: tab.minY + 2)); crimp.line(to: CGPoint(x: crimpX, y: tab.maxY - 2))
            let crimpX2 = isZeroEnd ? tab.maxX - 6 : tab.minX + 6
            crimp.move(to: CGPoint(x: crimpX2, y: tab.minY + 2)); crimp.line(to: CGPoint(x: crimpX2, y: tab.maxY - 2))
            metalEdge.withAlphaComponent(0.7).setStroke(); crimp.stroke()

            // Hang hole near the outer (rounded) end of each tab — one per end,
            // because the sewing box has two nails and she's not choosing.
            let holeX = isZeroEnd ? tab.minX + 3 : tab.maxX - 7
            let hole = NSBezierPath(ovalIn: NSRect(x: holeX, y: tab.midY - 2, width: 4, height: 4))
            NSColor.black.withAlphaComponent(0.45).setFill(); hole.fill()
        }
    }

    /// A crimp-tab outline rounded only at one end along the x axis: the outer
    /// (`roundedEndIsMax` picks which) — the other end stays square where the
    /// metal folds over the ribbon.
    private func tipPath(_ r: NSRect, roundedEndIsMax: Bool) -> NSBezierPath {
        let rad: CGFloat = 2.5
        let p = NSBezierPath()
        if roundedEndIsMax {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.line(to: CGPoint(x: r.maxX - rad, y: r.minY))
            p.appendArc(withCenter: CGPoint(x: r.maxX - rad, y: r.minY + rad),
                        radius: rad, startAngle: -90, endAngle: 0)
            p.line(to: CGPoint(x: r.maxX, y: r.maxY - rad))
            p.appendArc(withCenter: CGPoint(x: r.maxX - rad, y: r.maxY - rad),
                        radius: rad, startAngle: 0, endAngle: 90)
            p.line(to: CGPoint(x: r.minX, y: r.maxY))
        } else {
            p.move(to: CGPoint(x: r.maxX, y: r.maxY))
            p.line(to: CGPoint(x: r.minX + rad, y: r.maxY))
            p.appendArc(withCenter: CGPoint(x: r.minX + rad, y: r.maxY - rad),
                        radius: rad, startAngle: 90, endAngle: 180)
            p.line(to: CGPoint(x: r.minX, y: r.minY + rad))
            p.appendArc(withCenter: CGPoint(x: r.minX + rad, y: r.minY + rad),
                        radius: rad, startAngle: 180, endAngle: 270)
            p.line(to: CGPoint(x: r.maxX, y: r.minY))
        }
        p.close()
        return p
    }

    /// The tape's name — "inches" or her "inches" — in white over the blade's
    /// midpoint, parallel to the blade, on the side facing the screen's center.
    private func drawUnitLabel() {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 4
        let str = NSAttributedString(string: unitLabel, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.white,
            .shadow: shadow,
        ])
        let size = str.size()
        let gap: CGFloat = 14
        let y = centerSide > 0 ? Self.thickness + gap : -gap - size.height
        str.draw(at: CGPoint(x: length / 2 - size.width / 2, y: y))
    }
}

/// The tape's Stage: runs the y-up CoreGraphics pass under the same shim as the
/// schematic (flip once, wrap in an NSGraphicsContext).
struct TapeCanvasView: View {
    weak var tape: Tape?
    var generation: Int

    var body: some View {
        Canvas { ctx, size in
            _ = generation
            guard let tape else { return }
            ctx.withCGContext { cg in
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                let ns = NSGraphicsContext(cgContext: cg, flipped: false)
                let prev = NSGraphicsContext.current
                NSGraphicsContext.current = ns
                tape.draw()
                NSGraphicsContext.current = prev
            }
        }
    }
}

/// The tape's hosting view: hit-carving so two overlapping full-frame tapes share a
/// window (only grab regions claim clicks), drag classification, cursor rects, and
/// the arrow-key/⏎/⎋ routing. NSHostingView is flipped; the tape speaks y-up, so
/// points flip at this boundary.
final class TapeHost: NSHostingView<TapeCanvasView> {

    let tape: Tape
    private var generation = 0

    init(tape: Tape) {
        self.tape = tape
        super.init(rootView: TapeCanvasView(tape: tape, generation: 0))
        tape.onNeedsRepaint = { [weak self] in self?.repaint() }
        tape.onInvalidChanged = { [weak self] faded in self?.alphaValue = faded ? 0.3 : 1 }
        tape.onGrabRectsChanged = { [weak self] in
            guard let self else { return }
            self.window?.invalidateCursorRects(for: self)
        }
    }

    @MainActor required init(rootView: TapeCanvasView) { fatalError("use init(tape:)") }
    @MainActor required init?(coder: NSCoder) { fatalError() }

    private func repaint() {
        generation += 1
        rootView = TapeCanvasView(tape: tape, generation: generation)
    }

    override func layout() {
        super.layout()
        if tape.bounds.size != bounds.size {
            tape.bounds = CGRect(origin: .zero, size: bounds.size)
            repaint()
        }
    }

    /// This host is flipped (SwiftUI); the tape's geometry is y-up.
    private func yUp(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: bounds.height - p.y) }

    /// Two tapes share each screen as full-frame siblings; only claim clicks that
    /// actually land on this tape's grab regions so the rest fall through to the
    /// other tape.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sup = superview else { return nil }
        let local = convert(point, from: sup)
        return tape.claims(yUp(local)) ? self : nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = yUp(convert(event.locationInWindow, from: nil))
        if tape.beginGrab(at: p) { window?.makeFirstResponder(self) }
    }
    override func mouseDragged(with event: NSEvent) {
        tape.moveGrab(to: yUp(convert(event.locationInWindow, from: nil)))
    }
    override func mouseUp(with event: NSEvent) { tape.endGrab() }

    override func keyDown(with event: NSEvent) {
        if !tape.handleKey(code: event.keyCode, shift: event.modifierFlags.contains(.shift)) {
            super.keyDown(with: event)
        }
    }

    // Keep the active-tip glow honest as focus moves between the two tape
    // windows and the panel.
    override func becomeFirstResponder() -> Bool { syncKeyboardLive(); return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool {
        defer { syncKeyboardLive() }
        return super.resignFirstResponder()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let w = window else { return }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(keyStateChanged), name: NSWindow.didBecomeKeyNotification, object: w)
        nc.addObserver(self, selector: #selector(keyStateChanged), name: NSWindow.didResignKeyNotification, object: w)
    }
    @objc private func keyStateChanged() { syncKeyboardLive() }

    /// True while the floating panel is key and routing its arrow keys to this
    /// tape (the controller keeps it in sync with the panel's key status).
    var externallyActive = false {
        didSet { if externallyActive != oldValue { syncKeyboardLive() } }
    }

    /// Whether arrow keys would land on this tape right now — either directly
    /// (its window is key and it holds first responder) or via the panel.
    private func syncKeyboardLive() {
        // Defer a beat: first-responder/key state settles after the transition calls.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tape.keyboardIsLive = self.externallyActive
                || (self.window?.isKeyWindow == true && self.window?.firstResponder === self)
        }
    }

    override func resetCursorRects() {
        let resize: NSCursor = tape.lengthIsVertical ? .resizeUpDown : .resizeLeftRight
        let (lowR, highR, ribbonR) = tape.grabRects(tape.rect())
        // Cursor rects are in this (flipped) view's space; the tape's are y-up.
        func flip(_ r: NSRect) -> NSRect {
            NSRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
        }
        addCursorRect(flip(ribbonR), cursor: .openHand)
        addCursorRect(flip(lowR), cursor: resize)
        addCursorRect(flip(highR), cursor: resize)
    }
}
