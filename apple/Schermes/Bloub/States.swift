import CoreGraphics
import Foundation

nonisolated struct BloubEyeCfg: Equatable {
    /// local width (the capsule's short axis), in ball radii
    var w: Double
    /// local height (the long axis)
    var h: Double
    /// 1 = open, 0 = shut
    var open: Double
    /// The capsule's own tilt in degrees, positive tips the top to the right. Applied after the
    /// sphere's tangent frame. Without it both eyes must lean the same way (the head roll), which
    /// puts anger and sadness — mirrored tilts — out of reach.
    var tilt: Double = 0

    static func lerp(_ a: BloubEyeCfg, _ b: BloubEyeCfg, _ t: Double) -> BloubEyeCfg {
        BloubEyeCfg(
            w: bloubLerp(a.w, b.w, t),
            h: bloubLerp(a.h, b.h, t),
            open: bloubLerp(a.open, b.open, t),
            tilt: bloubLerp(a.tilt, b.tilt, t)
        )
    }
}

nonisolated struct BloubNotif {
    var x: Double
    var y: Double
    var r: Double
    var notch: Double
}

nonisolated struct BloubPose {
    /// the body outline, in ball radii
    var sil: BloubSilhouette
    /// offset of the body AND the eyes
    var offX: Double = 0
    var offY: Double = 0
    var gaze: BloubGaze = BloubFace.restGaze
    /// half the eye separation on the sphere, degrees
    var split: Double = BloubFace.split
    /// (inner eye, outer eye)
    var eyes: (BloubEyeCfg, BloubEyeCfg) = (
        BloubEyeCfg(w: BloubFace.eyeWidth, h: BloubFace.eyeHeight, open: 1),
        BloubEyeCfg(w: BloubFace.eyeWidth, h: BloubFace.eyeHeight, open: 1)
    )
    /// eye opacity: for the states with no face
    var eyeAlpha: Double = 1
    var bodyAlpha: Double = 1
    var dots: [BloubDot] = []
    var arcs: [BloubArcSpec] = []
    var notif: BloubNotif?
    /// true = the decor passes behind the body (the burst's particles)
    var dotsBehind: Bool = false
}

nonisolated enum BloubStateId: String, CaseIterable, Sendable {
    case idle, thinking, wink, wide, alert, notify, exclaim, sleep, egg, hexagon, play, orbit
    case burst, comet
    /// an interface transition, not one of the catalogue's animations: outside `sequence`
    case swirl
}

nonisolated struct BloubStateDef {
    var id: BloubStateId
    /// how long it is held when the full sequence plays
    var duration: Double
    /// the length below which the animation is cut off before it lands: the "!" does not come
    /// back, the body stays burst. It is read off the constants in `pose`, not chosen.
    var minDuration: Double?
    /// length of the entry morph
    var morph: Double
    /// true = the entry is hidden by a blink, as in the video
    var blinkIn: Bool
    /// true = the body is the resting silhouette, so the chosen shape can replace it. The states
    /// that draw their own shape (the "!", the dots, the egg, the triangle) are false: that shape
    /// IS the animation.
    var baseBody: Bool
    /// true = the state carries the resting face, so the chosen expression can replace it. Only
    /// `idle` and `swirl`: the other states with a face have one read off the video, which is
    /// precisely what is being reproduced.
    var baseFace: Bool
    var pose: @Sendable (Double) -> BloubPose
}

nonisolated private func pair(_ w: Double, _ h: Double) -> (BloubEyeCfg, BloubEyeCfg) {
    (BloubEyeCfg(w: w, h: h, open: 1), BloubEyeCfg(w: w, h: h, open: 1))
}

nonisolated private func base() -> BloubPose {
    BloubPose(sil: BloubGeometry.circle(1))
}

/// The upright "!" bar: the convex hull of two circles. Measured: top circle (0, -0.505) r 0.132,
/// bottom (0, +0.130) r 0.075, straight flanks — so it tapers, 1.76 top to bottom.
nonisolated private let barUprightCy: Double = -0.1875

nonisolated private func barUpright() -> BloubSilhouette {
    BloubSilhouette(radii: BloubTables.barUpright, cy: barUprightCy)
}

/// The tilted "!" bar: a pure capsule, constant width 0.269, length 0.776.
nonisolated private func barItalic(rot: Double, cx: Double, cy: Double) -> BloubSilhouette {
    BloubSilhouette(radii: BloubTables.barItalic, rot: rot, cx: cx, cy: cy)
}

/// The tilted "!" dot is not a disc: it is a teardrop, round end (r 0.118) towards the bar and a
/// drawn-out point the other way, 0.300 long along the glyph's axis.
nonisolated let bloubTeardrop: [CGPoint] = stride(from: 0, to: BloubTables.teardrop.count, by: 2)
    .map { CGPoint(x: BloubTables.teardrop[$0], y: BloubTables.teardrop[$0 + 1]) }

/// The triangle does not spin on itself: its centre traces a circle of radius 0.213 about the
/// origin (measured). That offset is what makes it look like it tips rather than pivots in place.
nonisolated private let triangleOrbit: Double = 0.213

nonisolated private func spinningTriangle(_ rot: Double) -> BloubSilhouette {
    BloubSilhouette(
        radii: BloubTables.triangleProfile,
        rot: rot,
        cx: -triangleOrbit * sin(rot),
        cy: triangleOrbit * cos(rot)
    )
}

/// A pulse travelling left to right across the three dots.
nonisolated private func dotPulse(_ t: Double, _ index: Int) -> Double {
    var p = ((t - Double(index) * 0.5) / 1.5).truncatingRemainder(dividingBy: 1)
    if p < 0 { p += 1 }
    let k = p < 0.5 ? 0.5 - 0.5 * cos(p * bloubTau) : 0
    return bloubClamp(k * 2)
}

nonisolated enum BloubStates {
    static let all: [BloubStateDef] = [
        BloubStateDef(
            id: .idle, duration: 2.4, minDuration: nil, morph: 0.45, blinkIn: false,
            baseBody: true, baseFace: true,
            pose: { _ in base() }
        ),

        BloubStateDef(
            id: .thinking, duration: 2.6, minDuration: nil, morph: 0.4, blinkIn: true,
            baseBody: false, baseFace: false,
            pose: { t in
                let mid = dotPulse(t, 1)
                // The side dots grow out of the ball's flanks: in the video they stay fused to it
                // for a frame or two before they break away.
                let emerge = 0.3 + 0.7 * BloubEase.outCubic(bloubClamp(t / 0.3))
                var p = base()
                // the ball BECOMES the middle dot, so the morph stays continuous
                p.sil = BloubGeometry.circle(BloubDecor.dotR * (1 + (BloubDecor.dotPeak - 1) * mid))
                p.sil.cx = BloubDecor.dotX[1]
                p.eyeAlpha = 0
                p.dots = [0, 2].map { i in
                    let k = dotPulse(t, i)
                    return BloubDot(
                        x: BloubDecor.dotX[i] * emerge,
                        y: 0,
                        r: BloubDecor.dotR * (1 + (BloubDecor.dotPeak - 1) * k),
                        opacity: 0.55 + 0.45 * k,
                        depth: nil
                    )
                }
                return p
            }
        ),

        BloubStateDef(
            id: .wink, duration: 1.6, minDuration: nil, morph: 0.3, blinkIn: true,
            baseBody: true, baseFace: false,
            pose: { _ in
                var p = base()
                p.gaze = BloubGaze(yaw: -5.37, pitch: 4.55, roll: 6.7)
                p.split = 16.25
                // The shut eye is not the open one squashed: it is a horizontal dash WIDER than
                // the open eye (0.447 against 0.236).
                p.eyes = (
                    BloubEyeCfg(w: 0.236, h: 0.464, open: 1),
                    BloubEyeCfg(w: 0.447, h: 0.089, open: 1)
                )
                return p
            }
        ),

        BloubStateDef(
            id: .wide, duration: 1.8, minDuration: nil, morph: 0.55, blinkIn: true,
            baseBody: true, baseFace: false,
            pose: { _ in
                var p = base()
                p.gaze = BloubGaze(yaw: 6.92, pitch: -21.96, roll: 11.6)
                p.split = 18.43
                p.eyes = pair(0.356, 0.875)
                return p
            }
        ),

        BloubStateDef(
            // the "!" comes back into place at 1.6 + 0.4
            id: .alert, duration: 2.4, minDuration: 2, morph: 0.45, blinkIn: false,
            baseBody: false, baseFace: false,
            pose: { t in
                // Measured run: -0.087 -> +0.732 in 1.5 s, ease-in-out, micro overshoot.
                let travel = BloubEase.inOutCubic(bloubClamp(t / 1.5)) * 0.82 - 0.087
                let back = t > 1.6 ? bloubClamp((t - 1.6) / 0.4) : 0
                let x = travel * (1 - back) + 0.1 * back
                // Secondary buzz at 2.5 Hz, bar and dot in antiphase.
                let buzz = sin(t * 2.5 * bloubTau) * 0.005
                let tilt = (17.7 * Double.pi) / 180
                var p = base()
                p.sil = barItalic(rot: tilt, cx: x, cy: -0.325 - buzz)
                p.eyeAlpha = 0
                p.dots = [BloubDot(
                    // the dot follows the glyph's axis, 0.580 from the bar's centre
                    x: x - sin(tilt) * 0.58,
                    y: -0.325 + cos(tilt) * 0.58 + buzz * 2.8,
                    r: 0.118,
                    opacity: 1,
                    depth: nil,
                    teardrop: true,
                    rot: (tilt * 180) / .pi
                )]
                return p
            }
        ),

        BloubStateDef(
            id: .notify, duration: 2.2, minDuration: nil, morph: 0.5, blinkIn: true,
            baseBody: true, baseFace: false,
            pose: { t in
                // Blue dot's pop: peaks +14 % around 0.3 s, then settles.
                let k = bloubClamp(t / 0.45)
                let pop = 1 + (BloubDecor.notifPop - 1) * sin(k * .pi) * (1 - k * 0.35)
                let r = BloubDecor.notifR * (k < 1 ? pop : 1)
                let a = (BloubDecor.notifAngle * Double.pi) / 180
                var p = base()
                // the gaze goes the opposite way from the badge
                p.gaze = BloubGaze(yaw: -21.94, pitch: -5.82, roll: -12.2)
                p.split = 18.89
                p.eyes = pair(0.505, 0.498)
                p.notif = BloubNotif(
                    x: cos(a) * BloubDecor.notifDistance,
                    y: sin(a) * BloubDecor.notifDistance,
                    r: r,
                    notch: r + BloubDecor.notifMargin
                )
                return p
            }
        ),

        BloubStateDef(
            id: .exclaim, duration: 2, minDuration: nil, morph: 0.45, blinkIn: false,
            baseBody: false, baseFace: false,
            pose: { _ in
                var p = base()
                p.sil = barUpright()
                p.eyeAlpha = 0
                p.dots = [BloubDot(x: -0.012, y: 0.526, r: 0.113, opacity: 1, depth: nil)]
                return p
            }
        ),

        BloubStateDef(
            id: .sleep, duration: 2.4, minDuration: nil, morph: 0.5, blinkIn: false,
            baseBody: false, baseFace: false,
            pose: { t in
                var p = base()
                // Measured vertical bounce: +-0.19 about +0.11, period 0.6 s.
                p.sil = BloubGeometry.circle(0.1585)
                p.sil.cy = 0.11 + sin(t * (bloubTau / 0.6)) * 0.19
                p.eyeAlpha = 0
                return p
            }
        ),

        BloubStateDef(
            id: .egg, duration: 1.8, minDuration: nil, morph: 0.4, blinkIn: true,
            baseBody: false, baseFace: false,
            pose: { _ in
                var p = base()
                p.sil = BloubSilhouette(radii: BloubTables.egg)
                p.gaze = BloubGaze(yaw: 19.97, pitch: 26.01, roll: -17.1)
                // the eyes draw together as the body does
                p.split = 11.07
                p.eyes = pair(0.164, 0.385)
                return p
            }
        ),

        BloubStateDef(
            id: .hexagon, duration: 1.6, minDuration: nil, morph: 0.4, blinkIn: true,
            baseBody: false, baseFace: false,
            pose: { _ in
                var p = base()
                p.sil = BloubSilhouette(radii: BloubTables.hexagonProfile)
                p.gaze = BloubGaze(yaw: 23.11, pitch: 24.42, roll: -13.3)
                p.split = 13.37
                p.eyes = pair(0.177, 0.411)
                return p
            }
        ),

        BloubStateDef(
            id: .play, duration: 2, minDuration: nil, morph: 0.5, blinkIn: true,
            baseBody: false, baseFace: false,
            pose: { t in
                // The triangle stays almost still while the bundle sweeps across it.
                let fade = bloubClamp(t / 0.35) * bloubClamp((2.2 - t) / 0.5)
                var p = base()
                p.sil = spinningTriangle(0)
                p.gaze = BloubGaze(yaw: 12, pitch: -8, roll: -6)
                p.split = 15
                p.eyes = pair(0.18, 0.34)
                // the bundle sweeps right to left over the triangle
                p.arcs = BloubDecor.swoosh.enumerated().map { i, s in
                    var seed = s
                    seed.cx = 0.45 - t * 0.42
                    return BloubArcSpec(id: "sw\(i)", seed: seed, t: t, opacity: fade)
                }
                return p
            }
        ),

        BloubStateDef(
            // the body has finished relaxing from the triangle to the ball at 1.6 + 0.9
            id: .orbit, duration: 3.4, minDuration: 2.5, morph: 0.6, blinkIn: false,
            baseBody: false, baseFace: false,
            pose: { t in
                // Measured rotation: ramps over 0.35 s then 1.25 turns a second, anticlockwise.
                let ramp = BloubEase.inOutCubic(bloubClamp(t / 0.35))
                let rot = -bloubTau * 1.25 * t * ramp
                // The body relaxes from the triangle back to the ball during the orbit.
                let back = BloubEase.inOutCubic(bloubClamp((t - 1.6) / 0.9))
                let tri = spinningTriangle(rot)
                var p = base()
                p.sil = BloubSilhouette(
                    radii: tri.radii.map { $0 + (1 - $0) * back },
                    rot: rot,
                    cx: tri.cx * (1 - back),
                    cy: tri.cy * (1 - back)
                )
                let fade = bloubClamp(t / 0.8) * bloubClamp((3.6 - t) / 0.9)
                // the eyes race round the sphere ~3x faster than the silhouette
                p.gaze = BloubGaze(
                    yaw: BloubFace.restGaze.yaw + sin(t * 6.5) * 65 * (1 - back),
                    pitch: -4 + back * 32,
                    roll: -13
                )
                p.eyes = pair(0.18, 0.34 + back * 0.07)
                // the rings come in one at a time over 0.8 s
                p.arcs = BloubDecor.rings.enumerated().map { i, s in
                    BloubArcSpec(
                        id: "rg\(i)",
                        seed: s,
                        t: t,
                        opacity: fade * bloubClamp((t - Double(i) * 0.13) / 0.3)
                    )
                }
                return p
            }
        ),

        BloubStateDef(
            // A bit longer than the gaze's turn: the eyes must be settled before the rings fade.
            //
            // The only state not read off the video: it is chosen. It borrows orbit's vocabulary —
            // the same rings, with their measured parameters — but cuts it short: 1 s instead of
            // 3.4, half the rings, and no triangle. Both flags are the whole point of it:
            // `baseBody` lets the chosen shape replace the body, so a pebble or a droplet morphs
            // into the circle instead of jumping; `baseFace` makes it carry the resting face, so a
            // state that had its own gaze would hand over mid-run and the eyes would jump.
            id: .swirl, duration: 1.3, minDuration: 1.3, morph: 0.3, blinkIn: true,
            baseBody: true, baseFace: true,
            pose: { t in
                var p = base()
                // three of orbit's six rings: half the bundle is enough to recognise it, and that
                // is as many arcs again not rasterised every frame
                p.arcs = BloubDecor.rings.prefix(3).enumerated().map { i, s in
                    BloubArcSpec(
                        id: "sw\(i)",
                        seed: s,
                        t: t,
                        // they come in one after another then fade before the block ends, so the
                        // return to rest happens on an already clean frame
                        opacity: bloubClamp((t - Double(i) * 0.06) / 0.14)
                            * bloubClamp((1.22 - t) / 0.34)
                    )
                }
                return p
            }
        ),

        BloubStateDef(
            // the body is back together at 1.7 + 0.7
            id: .burst, duration: 2.6, minDuration: 2.4, morph: 0.4, blinkIn: false,
            baseBody: false, baseFace: false,
            pose: { t in
                // Measured collapse: 1.0 -> 0.166 in 0.7 s, ease-out, no bounce.
                let collapse = 1 - 0.834 * BloubEase.outQuint(bloubClamp(t / 0.7))
                let regrow = BloubEase.outQuint(bloubClamp((t - 1.7) / 0.7))
                var p = base()
                p.sil = BloubGeometry.circle(collapse + (1 - collapse) * regrow)
                p.eyeAlpha = bloubClamp((t - 1.85) / 0.4)
                p.dots = BloubDecor.particles(t, 1)
                p.dotsBehind = true
                return p
            }
        ),

        BloubStateDef(
            // The dot comes back together at 1.85 + 0.6 = 2.45, 0.05 s after the video's cut: that
            // remainder finishes during the next fade, as in the reference. So it does not go
            // below the measured length.
            id: .comet, duration: 2.4, minDuration: 2.4, morph: 0.45, blinkIn: false,
            baseBody: false, baseFace: false,
            pose: { t in
                let collapse = 1 - (1 - BloubDecor.cometDot)
                    * BloubEase.outQuint(bloubClamp(t / 0.55))
                let regrow = BloubEase.outQuint(bloubClamp((t - 1.85) / 0.6))
                let fade = bloubClamp((t - 0.15) / 0.25) * bloubClamp((1.95 - t) / 0.3)
                var p = base()
                p.sil = BloubGeometry.circle(collapse + (1 - collapse) * regrow)
                // The dot drifts 0.035 down then comes back (measured wobble).
                p.sil.cy = sin(bloubClamp(t / 1.7) * .pi) * 0.035
                p.eyeAlpha = bloubClamp((t - 2) / 0.35)
                p.arcs = BloubDecor.cometRibbons.enumerated().map { i, s in
                    BloubArcSpec(id: "cm\(i)", seed: s, t: t, opacity: fade)
                }
                return p
            }
        )
    ]

    static let byId: [BloubStateId: BloubStateDef] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    /// The order the full sequence reads in, traced off the reference video.
    static let sequence: [BloubStateId] = [
        .idle, .thinking, .wink, .wide, .alert, .notify, .exclaim, .sleep, .egg, .hexagon, .play,
        .orbit, .burst, .comet
    ]

    /// The local time at which each state reads most clearly: the pose the thumbnails and the
    /// board show. Deterministic, so it is comparable from one run to the next.
    static func poseTime(_ id: BloubStateId) -> Double {
        switch id {
        case .idle: 1
        case .thinking: 1.1
        case .wink: 0.8
        case .wide: 0.8
        case .alert: 0.75
        case .notify: 0.9
        case .exclaim: 0.8
        case .sleep: 0.45
        case .egg: 0.8
        case .hexagon: 0.8
        case .play: 0.9
        case .orbit: 1.2
        case .swirl: 0.5
        case .burst: 0.45
        case .comet: 1.15
        }
    }
}
