import CoreGraphics
import Foundation

nonisolated struct BloubRenderedEye {
    /// capsule size in viewBox units, centred on the origin before the transform
    var w: Double
    var h: Double
    var transform: CGAffineTransform
    var alpha: Double
}

nonisolated struct BloubBlob {
    var x: Double
    var y: Double
    var r: Double
}

nonisolated struct BloubFrame {
    /// the body outline as 64 screen points; the view closes it into a smooth path
    var body: [CGPoint]
    var bodyAlpha: Double
    var eyes: [BloubRenderedEye]
    var dots: [BloubDot]
    /// true = the dots pass behind the body (the burst's particles)
    var dotsBehind: Bool
    var arcs: [BloubArcRender]
    var notif: BloubBlob?
    var notch: BloubBlob?
}

/// Where the head is aimed from outside the states, as in bloub's `Look`.
///
/// `yaw` and `pitch` REPLACE the pose's by `mix` rather than adding to it: added, the eyes' height
/// followed each expression's own pitch and dropped at the first change. `wander` is kept apart
/// because a drift on top of a follow reads as hunting for the cursor without ever holding it.
nonisolated struct BloubLook: Equatable {
    var yaw: Double
    var pitch: Double
    var mix: Double
    var wander: Double

    static let none = BloubLook(yaw: 0, pitch: 0, mix: 0, wander: 1)

    static func lerp(_ a: BloubLook, _ b: BloubLook, _ t: Double) -> BloubLook {
        BloubLook(
            yaw: bloubLerp(a.yaw, b.yaw, t),
            pitch: bloubLerp(a.pitch, b.pitch, t),
            mix: bloubLerp(a.mix, b.mix, t),
            wander: bloubLerp(a.wander, b.wander, t)
        )
    }
}

/// A clockless engine: `sample(_:)` is a pure function of time.
///
/// In practice that means pause, resume, slow motion and a jump to an arbitrary date all give
/// exactly the same picture, and the rendering is testable without a view.
nonisolated final class BloubEngine {
    /// radius of the resting ball, in viewBox units
    let scale: Double
    /// Where this avatar is in its life at rest, in seconds. Two avatars on the same phase blink
    /// and drift in step, which reads as one puppeteer behind them all.
    let phase: Double

    private var cur: BloubStateId
    private var prev: BloubStateId?
    /// A FROZEN starting pose, laid down only when a state change lands while a fade is already
    /// running. See `setState`.
    private var frozenStart: BloubPose?
    private var tCur: Double = 0
    private var tPrev: Double = 0
    private var blinkAt: Double = -10
    private var shape: BloubShapeId?
    private var shapePrev: BloubShapeId?
    private var shapeAt: Double = -10
    private var expression: BloubExpressionId?
    private var expressionPrev: BloubExpressionId?
    private var expressionAt: Double = -10
    private var look = BloubLook.none
    private var lookPrev = BloubLook.none
    private var lookAt: Double = -10
    private var lookMorph = BloubEngine.lookMorph

    /// How long the morph takes when the body's shape changes.
    static let shapeMorph: Double = 0.45
    /// How long the gaze takes to catch a new look.
    static let lookMorph: Double = 0.24

    init(
        scale: Double = Bloub.radius,
        state: BloubStateId = .idle,
        shape: BloubShapeId? = nil,
        expression: BloubExpressionId? = nil,
        phase: Double = 0
    ) {
        self.scale = scale
        self.phase = phase
        cur = state
        self.shape = shape
        self.expression = expression
    }

    var state: BloubStateId { cur }

    /// The resting expression. Like the shape, it slides to its new value instead of jumping.
    func setExpression(_ id: BloubExpressionId?, now: Double) {
        if id == expression { return }
        expressionPrev = expression
        expression = id
        expressionAt = now
    }

    /// Aims the head, dated like the other setters, so `sample` stays a pure function of time.
    ///
    /// Called on every frame while the pointer moves, so the catch-up starts from the look ON
    /// SCREEN, not the previous target: starting from the target makes the follow judder. A
    /// non-finite look is refused, because the engine keeps the last one and a single NaN would
    /// stay in every frame after it.
    func setLook(_ target: BloubLook?, now: Double, morph: Double = BloubEngine.lookMorph) {
        let next = target ?? .none
        guard (next.yaw + next.pitch + next.mix + next.wander).isFinite else { return }
        lookPrev = lookOnScreen(at: now)
        look = next
        lookAt = now
        lookMorph = morph
    }

    private func lookOnScreen(at now: Double) -> BloubLook {
        let k = (now - lookAt) / lookMorph
        if k >= 1 { return look }
        return BloubLook.lerp(lookPrev, look, BloubEase.outQuint(bloubClamp(k)))
    }

    /// The chosen shape. It only replaces the body on the resting states (`baseBody`): on the
    /// others the silhouette IS the animation and must not be overwritten.
    func setShape(_ id: BloubShapeId?, now: Double) {
        if id == shape { return }
        shapePrev = shape
        shape = id
        shapeAt = now
    }

    /// Changes state, dated.
    ///
    /// The engine keeps only ONE slot of history, so a change landing during a fade used to make
    /// the blend's origin the FULL pose of the state being left instead of the partly blended
    /// frame that was on screen. Measured on `idle -> wide -> idle` at 100 ms: a 35.9 px jump
    /// against 8.0 px of normal movement. So the composite pose is frozen and the blend starts
    /// from it — continuous by construction however many changes are chained.
    ///
    /// And ONLY in that case. Freezing on every change would stop the outgoing state's animation
    /// dead for the whole fade — the "!" would halt mid-run — when there is nothing to fix outside
    /// a morph.
    func setState(_ id: BloubStateId, now: Double) {
        if id == cur { return }
        let morph = BloubStates.byId[cur]!.morph
        let midFade = prev != nil && now - tCur < morph
        frozenStart = midFade ? composed(now) : nil
        prev = cur
        tPrev = tCur
        cur = id
        tCur = now
        // In the video every shape change is masked by a blink.
        if BloubStates.byId[id]?.blinkIn == true { blinkAt = now }
    }

    /// Restarts on `id` with NO previous state, like a fresh engine placed on it. `setState` alone
    /// cannot do this: it keeps the state being left so it can fade it, which is exactly its job
    /// on playback and exactly what is wrong when returning to the start of a sequence.
    func reset(_ id: BloubStateId, now: Double) {
        cur = id
        prev = nil
        frozenStart = nil
        tCur = now
        tPrev = now
        blinkAt = -10
    }

    /// The effective profile at `now`, morph included.
    ///
    /// Does NOT clear `shapePrev` when the morph ends: `sample` must stay a pure function of time,
    /// so reading a past date has to give the intermediate picture back.
    private func shapeRadii(at now: Double) -> [Double]? {
        guard let to = shape else { return nil }
        guard let from = shapePrev else { return to.radii }
        let k = (now - shapeAt) / Self.shapeMorph
        if k >= 1 { return to.radii }
        let t = BloubEase.outQuint(bloubClamp(k))
        let a = from.radii
        let b = to.radii
        return (0..<b.count).map { bloubLerp(a[$0], b[$0], t) }
    }

    private func expression(at now: Double) -> BloubExpression? {
        guard let to = expression else { return nil }
        guard let from = expressionPrev else { return to.expression }
        let k = (now - expressionAt) / Self.shapeMorph
        if k >= 1 { return to.expression }
        return bloubBlendExpression(
            from.expression,
            to.expression,
            BloubEase.outQuint(bloubClamp(k))
        )
    }

    private func posed(
        _ def: BloubStateDef,
        _ t: Double,
        _ radii: [Double]?,
        _ expr: BloubExpression?
    ) -> BloubPose {
        var pose = def.pose(t)
        if def.baseBody, let radii {
            // keep the pose (rotation, offset, squash) and swap only the profile
            pose.sil.radii = radii
        }
        if def.baseFace, let expr {
            pose.gaze = expr.gaze
            pose.split = expr.split
            pose.eyes = expr.eyes
        }
        return pose
    }

    /// The eye offset at `now` for a given state, in ball radii.
    ///
    /// It is READ from a table and interpolated, never recomputed: `BloubEyefit` explains why that
    /// distinction is the whole fix. The table is asked about the morph's BOUNDS, never about the
    /// interpolated profile — that one is a fresh array with no identity and exists in no table.
    private func eyeOffset(at now: Double, state: BloubStateId, following: Bool = false) -> CGPoint {
        /// One morph axis: read the table on its two bounds and interpolate with its curve.
        func onAxis(_ start: Double, _ duration: Double, _ a: CGPoint, _ b: CGPoint) -> CGPoint {
            if a == b { return b }
            let k = (now - start) / duration
            if k >= 1 { return b }
            let t = BloubEase.outQuint(bloubClamp(k))
            return CGPoint(x: bloubLerp(a.x, b.x, t), y: bloubLerp(a.y, b.y, t))
        }

        // the expression axis, for each of the two shapes in play
        func perShape(_ id: BloubShapeId?) -> CGPoint {
            onAxis(
                expressionAt,
                Self.shapeMorph,
                BloubEyefit.offset(
                    shape: id, state: state, expression: expressionPrev, following: following
                ),
                BloubEyefit.offset(shape: id, state: state, expression: expression, following: following)
            )
        }

        // then the shape axis
        return onAxis(shapeAt, Self.shapeMorph, perShape(shapePrev), perShape(shape))
    }

    /// Where the running fade starts: the frozen pose if there is one, otherwise the state being
    /// left evaluated at its own elapsed time — so still animating, which is intended.
    private func origin(_ now: Double, _ radii: [Double]?, _ expr: BloubExpression?) -> BloubPose? {
        if let frozenStart { return frozenStart }
        guard let prev else { return nil }
        return posed(BloubStates.byId[prev]!, max(0, now - tPrev), radii, expr)
    }

    /// The composite pose at `now`, running fade included: exactly what `sample` blends, before
    /// the layer of life at rest. Split out so `setState` can freeze it.
    private func composed(_ now: Double) -> BloubPose {
        let def = BloubStates.byId[cur]!
        let radii = shapeRadii(at: now)
        let expr = expression(at: now)
        let pose = posed(def, max(0, now - tCur), radii, expr)
        let since = now - tCur
        if since >= def.morph { return pose }
        guard let from = origin(now, radii, expr) else { return pose }
        return Self.blend(from, pose, BloubEase.outQuint(bloubClamp(since / def.morph)))
    }

    /// Interpolates two poses. The decor cross-fades in opacity, not in geometry.
    private static func blend(_ a: BloubPose, _ b: BloubPose, _ t: Double) -> BloubPose {
        let out = 1 - t
        var p = BloubPose(sil: BloubGeometry.blend(a.sil, b.sil, t))
        p.offX = bloubLerp(a.offX, b.offX, t)
        p.offY = bloubLerp(a.offY, b.offY, t)
        p.gaze = BloubGaze(
            yaw: bloubLerp(a.gaze.yaw, b.gaze.yaw, t),
            pitch: bloubLerp(a.gaze.pitch, b.gaze.pitch, t),
            roll: bloubLerp(a.gaze.roll, b.gaze.roll, t)
        )
        p.split = bloubLerp(a.split, b.split, t)
        p.eyes = (
            BloubEyeCfg.lerp(a.eyes.0, b.eyes.0, t),
            BloubEyeCfg.lerp(a.eyes.1, b.eyes.1, t)
        )
        p.eyeAlpha = bloubLerp(a.eyeAlpha, b.eyeAlpha, t)
        p.bodyAlpha = bloubLerp(a.bodyAlpha, b.bodyAlpha, t)
        p.dots = a.dots.map { var d = $0; d.opacity *= out; return d }
            + b.dots.map { var d = $0; d.opacity *= t; return d }
        p.arcs = a.arcs.map { BloubArcSpec(id: "a\($0.id)", seed: $0.seed, t: $0.t, opacity: $0.opacity * out) }
            + b.arcs.map { BloubArcSpec(id: "b\($0.id)", seed: $0.seed, t: $0.t, opacity: $0.opacity * t) }
        // the badge belongs to one of the two states; it does not blend
        p.notif = t < 0.5 ? a.notif : b.notif
        p.dotsBehind = t < 0.5 ? a.dotsBehind : b.dotsBehind
        return p
    }

    /// One frame at `now`. `decorStill` holds the orbit rings and the comet ribbons at their phase
    /// origin for Reduce Motion; everything else — the morph, the blink, the drift — keeps moving.
    func sample(_ now: Double, decorStill: Bool = false) -> BloubFrame {
        let r = scale
        let def = BloubStates.byId[cur]!
        let radii = shapeRadii(at: now)
        let expr = expression(at: now)
        var pose = posed(def, max(0, now - tCur), radii, expr)
        var offset = eyeOffset(at: now, state: cur)

        // --- transition ------------------------------------------------------
        let since = now - tCur
        // The previous state is never purged: `since < def.morph` is enough to ignore it once the
        // fade is over, and forgetting it would make the engine unreplayable.
        if since < def.morph, let from = origin(now, radii, expr) {
            // Exponential ease-out: the curve measured on the video. The ratio is clamped, or
            // reading a date BEFORE the state change gives a negative one, which the ease-out
            // extrapolates and the silhouette flies thirty times too far.
            let ratio = BloubEase.outQuint(bloubClamp(since / def.morph))
            pose = Self.blend(from, pose, ratio)
            // The eye offset follows the SAME curve as the silhouette that motivates it.
            if let left = prev {
                let before = eyeOffset(at: now, state: left)
                offset = CGPoint(
                    x: bloubLerp(before.x, offset.x, ratio),
                    y: bloubLerp(before.y, offset.y, ratio)
                )
            }
        }

        // --- life at rest ----------------------------------------------------
        let alive = pose.eyeAlpha > 0.01
        let aimed = lookOnScreen(at: now)
        let life = bloubLiveliness(now + phase, wander: alive ? aimed.wander : 0, blink: alive)
        if aimed.mix > 0 {
            let followed = eyeOffset(at: now, state: cur, following: true)
            offset = CGPoint(
                x: bloubLerp(offset.x, followed.x, aimed.mix),
                y: bloubLerp(offset.y, followed.y, aimed.mix)
            )
        }

        let gaze = BloubGaze(
            yaw: bloubLerp(pose.gaze.yaw, aimed.yaw, aimed.mix) + life.dYaw,
            pitch: bloubLerp(pose.gaze.pitch, aimed.pitch, aimed.mix) + life.dPitch,
            // the roll follows nothing: the head is tilted -13 degrees in the video and rolling it
            // breaks that signature
            roll: pose.gaze.roll + life.dRoll
        )

        // a blink triggered by the state change, on top of the schedule
        let forced = bloubClamp((now - blinkAt) / 0.2)
        let forcedLid = forced < 1 ? bloubLidCurve(forced) : 1
        let lid = min(life.lid, forcedLid)

        let offX = pose.offX + life.driftX
        let offY = pose.offY + life.driftY

        // --- body ------------------------------------------------------------
        var sil = pose.sil
        sil.cx += offX
        sil.cy += offY
        sil.sy *= life.breath
        let body = BloubGeometry.points(sil, r)

        // --- eyes ------------------------------------------------------------
        // The eyes live on a sphere of radius 1; the moment the silhouette is no longer a circle
        // they are pulled back in proportion to the real radius in their direction, or they spill
        // out and the mask cuts them.
        func bodyRadius(_ x: Double, _ y: Double) -> Double {
            BloubGeometry.radius(pose.sil.radii, at: atan2(y, x) - pose.sil.rot)
        }

        var eyes: [BloubRenderedEye] = []
        if pose.eyeAlpha > 0.01 {
            let poses = bloubEyePoses(gaze, r, pose.split)
            for i in 0..<2 {
                let e = i == 0 ? poses.0 : poses.1
                if e.depth <= 0.02 { continue }
                let cfg = i == 0 ? pose.eyes.0 : pose.eyes.1
                let fit = bodyRadius(e.x, e.y)
                // The eye's own tilt: the tangent frame composed with a rotation in the eye's
                // plane. That is what allows mirrored tilts between the two eyes.
                let phi = (cfg.tilt * Double.pi) / 180
                let cp = cos(phi)
                let sp = sin(phi)
                let ax = e.a * cp + e.c * sp
                let ay = e.b * cp + e.d * sp
                let cx = -e.a * sp + e.c * cp
                let cy = -e.b * sp + e.d * cp
                // The blink applies AFTER all of that: a vertical squash on screen, not one along
                // the capsule's axis.
                let k = bloubBlinkScale(min(lid, cfg.open))
                eyes.append(BloubRenderedEye(
                    w: cfg.w * r,
                    h: cfg.h * r,
                    transform: CGAffineTransform(
                        a: ax, b: ay * k,
                        c: cx, d: cy * k,
                        tx: e.x * fit + (offX + offset.x) * r,
                        ty: e.y * fit + (offY + offset.y) * r
                    ),
                    alpha: pose.eyeAlpha * bloubClamp(e.depth / 0.12)
                ))
            }
        }

        // --- decor -----------------------------------------------------------
        let dots = pose.dots
            .filter { $0.opacity > 0.01 && $0.r > 0.0005 }
            .map { dot -> BloubDot in
                var d = dot
                d.x = (dot.x + offX) * r
                d.y = (dot.y + offY) * r
                d.r = dot.r * r
                return d
            }

        // the badge sits on the outline, so it follows the shape too
        var notif: BloubBlob?
        var notch: BloubBlob?
        if let n = pose.notif {
            let fit = bodyRadius(n.x, n.y)
            let nx = (n.x * fit + offX) * r
            let ny = (n.y * fit + offY) * r
            notif = BloubBlob(x: nx, y: ny, r: n.r * r)
            notch = BloubBlob(x: nx, y: ny, r: n.notch * r)
        }

        return BloubFrame(
            body: body,
            bodyAlpha: pose.bodyAlpha,
            eyes: eyes,
            dots: dots,
            dotsBehind: pose.dotsBehind,
            // States declare arcs in ball radii; the engine is the only thing that knows the
            // viewBox scale, so it rasterises them.
            arcs: pose.arcs
                .filter { $0.opacity > 0.01 }
                .map { bloubArcRender($0.seed, decorStill ? 0 : $0.t, r, $0.id, $0.opacity) },
            notif: notif,
            notch: notch
        )
    }
}
