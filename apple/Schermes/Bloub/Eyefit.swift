import CoreGraphics
import Foundation

/// Where to put the face on a customiser shape.
///
/// The eyes live on a sphere and `BloubGeometry.radius(_:at:)` pulls them back onto the real
/// outline in proportion to the local radius. That proportion places their CENTRE correctly, but
/// an eye has a size: the margin left in front of the edge is scaled by the same factor, so a
/// silhouette that is narrow in that direction pushes the eye against the edge until the mask
/// opens it outwards. The capsule showed up as a notch in the body on capsule, triangle, cloud and
/// droplet.
///
/// This solves the problem ONCE, at startup, and yields a table of offsets. That choice is the
/// whole fix, far more than the geometry that follows: solved inside the render loop the
/// correction reacts to everything that moves at sixty frames a second, and bloub's own notes
/// record seven variants written that way, every one of them with a visible motion artefact.
/// Interpolating between two constants is monotone by construction; re-solving on a gaze that is
/// itself mid-interpolation is not.
nonisolated enum BloubEyefit {
    /// The solver's reference radius. The offset it returns is in units of that radius.
    private static let r = Bloub.radius

    /// Peak amplitudes of the life at rest, read off `bloubLiveliness`: `bloubLoopNoise` is bounded
    /// by 1 in absolute value and the glance fits inside the first term's budget, so these sums
    /// are exact bounds. They must be covered, or the correction is right on the nominal pose and
    /// wrong a second later — seven degrees of yaw move an eye a dozen units on a ball of radius
    /// 100.
    private static let driftYaw = 5.5 + 1.6
    private static let driftPitch = 4.2 + 1.3
    /// Float of the centre, in ball radii.
    private static let driftX = 0.006
    private static let driftY = 0.007

    /// Float of the centre, in viewBox units. It is added to the eye's radius: less than one unit,
    /// so absorbing it this way is cheaper than multiplying the trials by its four corners.
    private static let float = (driftX * driftX + driftY * driftY).squareRoot() * Bloub.radius

    /// Directions probed and bisection steps. Their product is the cost of building the table.
    private static let directions = 12
    private static let bisections = 8

    /// The face of a pose: what the solver needs to place its capsules.
    private struct Visage {
        var gaze: BloubGaze
        var split: Double
        var eyes: (BloubEyeCfg, BloubEyeCfg)
    }

    /// A capsule ready to be measured: the segment of its axis, and what it takes to work out the
    /// radius to clear IN A GIVEN DIRECTION.
    ///
    /// A capsule is exactly a segment thickened by a disc of radius `r`. Its image under the
    /// tangent matrix is therefore a segment thickened by an ELLIPSE, and the radius to clear
    /// depends on the direction: it is that ellipse's support function, `r * |A^T u|`. Taking its
    /// largest singular value instead would be conservative but wrong in the one direction that
    /// matters, and that costs dearly — the reference margin on the circle came out NEGATIVE.
    private struct Print {
        var x: Double
        var y: Double
        var ax: Double
        var ay: Double
        var r: Double
        var m: (Double, Double, Double, Double)
    }

    private struct Trial {
        var prints: [Print]
        var reference: [Print]
        var contour: [CGPoint]
        var calContour: [CGPoint]
    }

    /// Prints of a face's two eyes, laid on a profile. A shut eye needs no room made for it, so
    /// the blink is not in here.
    private static func prints(_ visage: Visage, _ sil: BloubSilhouette, _ radii: [Double]) -> [Print] {
        var out: [Print] = []
        let poses = bloubEyePoses(visage.gaze, r, visage.split)
        for i in 0..<2 {
            let e = i == 0 ? poses.0 : poses.1
            if e.depth <= 0.02 { continue }
            let cfg = i == 0 ? visage.eyes.0 : visage.eyes.1
            let phi = (cfg.tilt * Double.pi) / 180
            let cp = cos(phi)
            let sp = sin(phi)
            let ax = e.a * cp + e.c * sp
            let ay = e.b * cp + e.d * sp
            let cx = -e.a * sp + e.c * cp
            let cy = -e.b * sp + e.d * cp

            let hw = max(cfg.w * r, 0.01) / 2
            let hh = max(cfg.h * r, 0.01) / 2
            let radius = min(hw, hh)
            // the axis is the longer dimension's
            let long = hh > hw
            let half = long ? hh - radius : hw - radius
            // the local radius proportion, exactly as the engine does it
            let fit = BloubGeometry.radius(radii, at: atan2(e.y, e.x) - sil.rot)
            out.append(Print(
                x: e.x * fit,
                y: e.y * fit,
                ax: (long ? cx : ax) * half,
                ay: (long ? cy : ay) * half,
                r: radius,
                m: (ax, ay, cx, cy)
            ))
        }
        return out
    }

    /// The closest approach between an outline and a segment: the distance, and the vector from
    /// the outline towards the segment — the way that clears it. Both come out of the SAME pass;
    /// computing them separately doubled this module's only real cost, which is the sweep.
    private static func approach(
        _ pts: [CGPoint],
        _ x0: Double,
        _ y0: Double,
        _ x1: Double,
        _ y1: Double
    ) -> (d: Double, ux: Double, uy: Double) {
        let sx = x1 - x0
        let sy = y1 - y0
        let len2 = sx * sx + sy * sy
        var best = Double.infinity
        var vx = 0.0
        var vy = 0.0
        for p in pts {
            var t = len2 > 0 ? ((p.x - x0) * sx + (p.y - y0) * sy) / len2 : 0
            t = t < 0 ? 0 : (t > 1 ? 1 : t)
            let ex = x0 + t * sx - p.x
            let ey = y0 + t * sy - p.y
            let d2 = ex * ex + ey * ey
            if d2 < best {
                best = d2
                vx = ex
                vy = ey
            }
        }
        let d = best.squareRoot()
        return (d, d > 1e-9 ? vx / d : 0, d > 1e-9 ? vy / d : 0)
    }

    /// The margin of the tightest capsule, and the way that clears it.
    private static func worst(
        _ pts: [CGPoint],
        _ ps: [Print],
        _ tx: Double,
        _ ty: Double
    ) -> Double {
        var margin = Double.infinity
        for e in ps {
            let x = e.x + tx
            let y = e.y + ty
            let a = approach(pts, x - e.ax, y - e.ay, x + e.ax, y + e.ay)
            // the ellipse's support function in the approach's direction
            let (m0, m1, m2, m3) = e.m
            let sx = m0 * a.ux + m1 * a.uy
            let sy = m2 * a.ux + m3 * a.uy
            let radius = e.r * (sx * sx + sy * sy).squareRoot() + float
            margin = min(margin, a.d - radius)
        }
        return margin
    }

    /// The offset to put on both eyes for this shape, this state and this expression.
    ///
    /// One TRANSLATION common to both eyes, so an isometry: separation, sizes and tilts are kept
    /// to the pixel. The face is simply set a little lower on a body with no room at the top,
    /// which is the move one would make by hand.
    ///
    /// The margin aimed at is the ORIGINAL profile's, not a strict clearance: on the circle the
    /// outer eye already grazes the edge, 17.3 units on a ball of radius 100, and that is
    /// deliberate — it is what gives the volume. It is capped by what the shape offers at its
    /// centre, or the demand is unmeetable on a flat body.
    ///
    /// A DIRECTIONAL SEARCH, not a descent. We want the shortest translation that fits, so we
    /// probe a ring of directions and bisect the distance along each. A gradient descent was
    /// written first and does not converge: clearing the pair from one edge moves it towards the
    /// other. Here the result does not depend on convergence — each direction is solved exactly,
    /// to within the bisection step.
    private static func solve(_ trials: [Trial]) -> CGPoint {
        guard !trials.isEmpty else { return .zero }

        func margin(_ tx: Double, _ ty: Double) -> Double {
            var m = Double.infinity
            for trial in trials { m = min(m, worst(trial.contour, trial.prints, tx, ty)) }
            return m
        }

        // Required margin: the tightest the original profile tolerates, over every trial. Then
        // capped by the most room the shape can offer the pair, at its centre.
        var required = Double.infinity
        for trial in trials {
            required = min(required, worst(trial.calContour, trial.reference, 0, 0))
        }
        // The run has to be able to reach the body's centre: `wide` has capsules 87 units long,
        // and on a triangle they only fit near the middle, some fifty units from their nominal
        // place. A fixed run left them outside.
        var mx = 0.0
        var my = 0.0
        let ps = trials[0].prints
        for e in ps {
            mx -= e.x / Double(ps.count)
            my -= e.y / Double(ps.count)
        }
        let run = max(0.35 * r, (mx * mx + my * my).squareRoot() * 1.25)

        required = min(required, margin(mx, my))

        // Already fine: the circle's case, and any shape wide enough. The capsule must FIT as well
        // as be no tighter than on the original profile — without that second condition a shape
        // where nothing fits satisfies the first degenerately and the search gives up.
        let start = margin(0, 0)
        if start >= required && start >= 0 { return .zero }
        let target = max(required, 0)

        var bestX = 0.0
        var bestY = 0.0
        var bestNorm = Double.infinity
        // fallback when nothing fits: the translation that clears the most, probed on the way
        var fallbackX = 0.0
        var fallbackY = 0.0
        var fallback = start

        for d in 0..<directions {
            let a = (Double(d) / Double(directions)) * .pi * 2
            let ux = cos(a)
            let uy = sin(a)
            if margin(ux * run, uy * run) < target {
                // no solution that way, but maybe a better clearance
                for k in [0.3, 0.6, 1.0] {
                    let m = margin(ux * run * k, uy * run * k)
                    if m > fallback {
                        fallback = m
                        fallbackX = ux * run * k
                        fallbackY = uy * run * k
                    }
                }
                continue
            }
            // the shortest distance that fits, along this direction
            var low = 0.0
            var high = run
            for _ in 0..<bisections {
                let mid = (low + high) / 2
                if margin(ux * mid, uy * mid) >= target { high = mid } else { low = mid }
            }
            if high < bestNorm {
                bestNorm = high
                bestX = ux * high
                bestY = uy * high
            }
        }

        let x = bestNorm == .infinity ? fallbackX : bestX
        let y = bestNorm == .infinity ? fallbackY : bestY
        // returned in BALL RADII: the engine puts it back on its own scale
        let round6 = { (v: Double) in (v / r * 1_000_000).rounded() / 1_000_000 }
        return CGPoint(x: round6(x), y: round6(y))
    }

    /// The face to cover: the expression's if the state accepts one, its own otherwise.
    ///
    /// ONE table entry per expression, not one worst case shared by all. A worst case looked safer
    /// but is unmeetable: on a capsule, the neutral face has the eyes high and needs to come down
    /// where the scared one has them low and needs to go up.
    private static func visage(
        _ def: BloubStateDef,
        _ pose: BloubPose,
        _ expr: BloubExpression?
    ) -> Visage {
        if def.baseFace, let expr {
            return Visage(gaze: expr.gaze, split: expr.split, eyes: expr.eyes)
        }
        return Visage(gaze: pose.gaze, split: pose.split, eyes: pose.eyes)
    }

    /// The dates to sample within a state: just one if its pose does not move.
    private static func dates(_ def: BloubStateDef) -> [Double] {
        func signature(_ p: BloubPose) -> [Double] {
            [p.gaze.yaw, p.gaze.pitch, p.gaze.roll, p.split,
             p.eyes.0.w, p.eyes.0.h, p.eyes.0.open, p.eyes.0.tilt,
             p.eyes.1.w, p.eyes.1.h, p.eyes.1.open, p.eyes.1.tilt,
             p.sil.rot, p.sil.cx, p.sil.cy, p.sil.sx, p.sil.sy]
        }
        if signature(def.pose(0)) == signature(def.pose(def.duration)) { return [0] }
        return (0..<3).map { Double($0) / 2 * def.duration }
    }

    /// One shape's offset on one state and one expression, drift included. While `following`, the
    /// gaze is the pointer's instead, over everything `BloubLook.following` can reach: the drift
    /// is off then, and the state's own gaze gives way to the look's.
    private static func offset(
        _ def: BloubStateDef,
        _ radii: [Double],
        _ expr: BloubExpression?,
        following: Bool
    ) -> CGPoint {
        var trials: [Trial] = []
        for t in dates(def) {
            let pose = def.pose(t)
            var swapped = pose.sil
            swapped.radii = radii
            let contour = BloubGeometry.points(swapped, r)
            let calContour = BloubGeometry.points(pose.sil, r)
            let v = visage(def, pose, expr)
            // The corners bound the nominal pose, which is their centre: testing it as well would
            // change no margin and cost one more trial. The pointer's aim is at most 1 long, so
            // while following the corners are eight points round that circle.
            let corners: [(yaw: Double, pitch: Double)] = following
                ? (0..<8).map {
                    let a = Double($0) / 8 * bloubTau
                    let reach = def.id.pointerReach ?? 0
                    let look = BloubLook.following(nx: cos(a) * reach, ny: sin(a) * reach)
                    return (look.yaw, look.pitch)
                }
                : [-driftYaw, driftYaw].flatMap { dy in
                    [-driftPitch, driftPitch].map { (v.gaze.yaw + dy, v.gaze.pitch + $0) }
                }
            for corner in corners {
                var cornered = v
                cornered.gaze = BloubGaze(yaw: corner.yaw, pitch: corner.pitch, roll: v.gaze.roll)
                trials.append(Trial(
                    prints: prints(cornered, pose.sil, radii),
                    reference: prints(cornered, pose.sil, pose.sil.radii),
                    contour: contour,
                    calContour: calContour
                ))
            }
        }
        return solve(trials)
    }

    private struct Key: Hashable {
        var shape: BloubShapeId
        var state: BloubStateId
        var expression: BloubExpressionId?
        var following: Bool
    }

    /// Built on first use: one entry per (shape, base-body state, expression). `static let` is
    /// lazy and thread safe, so the solve happens once, off the render loop, and never per frame.
    private static let table: [Key: CGPoint] = {
        var out: [Key: CGPoint] = [:]
        for shape in BloubShapeId.allCases {
            let radii = shape.radii
            for def in BloubStates.all where def.baseBody {
                let expressions: [BloubExpressionId?] =
                    def.baseFace ? [nil] + BloubExpressionId.allCases.map { $0 } : [nil]
                for expression in expressions {
                    for following in def.id.pointerReach != nil ? [false, true] : [false] {
                        out[Key(shape: shape, state: def.id, expression: expression, following: following)] =
                            offset(def, radii, expression?.expression, following: following)
                    }
                }
            }
        }
        return out
    }()

    /// The offset to apply to both eyes for this shape on this state, in ball radii — the engine
    /// puts it back on its own scale. Zero when there is no shape, which covers the circle too:
    /// there both profiles are the same, so the margin is already the one required.
    static func offset(
        shape: BloubShapeId?,
        state: BloubStateId,
        expression: BloubExpressionId?,
        following: Bool = false
    ) -> CGPoint {
        guard let shape else { return .zero }
        // a state with no resting face has one entry whatever the expression
        func entry(_ following: Bool) -> CGPoint? {
            table[Key(shape: shape, state: state, expression: expression, following: following)]
                ?? table[Key(shape: shape, state: state, expression: nil, following: following)]
        }
        // a state that does not follow the pointer has only its resting entries
        return (following ? entry(true) : nil) ?? entry(false) ?? .zero
    }
}
