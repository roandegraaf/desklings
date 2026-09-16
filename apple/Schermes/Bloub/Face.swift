import Foundation

/// The eyes are painted on a sphere, not laid flat.
///
/// Measured: the eye nearest the edge is 0.69 times the width of the other and 0.663 times its
/// area, exactly the depth factor of a sphere point at that distance from the centre. So the model
/// is a real head orientation: each eye takes the sphere's tangent frame, projected
/// orthographically, and the squeeze and the tilt fall out of it. The constants below were fitted
/// to positions measured frame by frame, not chosen.
nonisolated enum BloubFace {
    /// Half the eye separation on the sphere, in degrees (total ~31).
    static let split: Double = 15.46
    /// Resting eye size, in ball radii.
    static let eyeWidth: Double = 0.186
    static let eyeHeight: Double = 0.412
    /// Resting head orientation, fitted on the reference frames.
    static let restGaze = BloubGaze(yaw: 28.49, pitch: 28.62, roll: -13)
}

nonisolated struct BloubGaze: Equatable {
    /// degrees, positive looks right
    var yaw: Double
    /// degrees, positive looks up
    var pitch: Double
    /// degrees, head tilt
    var roll: Double
}

nonisolated struct BloubEyePose {
    var x: Double
    var y: Double
    /// tangent 2x2 matrix, in the sense of an affine transform's a, b, c, d
    var a: Double
    var b: Double
    var c: Double
    var d: Double
    /// z of the normal: positive means the face is towards the viewer
    var depth: Double
}

private typealias Vec3 = (Double, Double, Double)

nonisolated private func bloubDeg(_ d: Double) -> Double { d * .pi / 180 }

/// Rotates two vectors of an orthonormal frame within their common plane.
nonisolated private func bloubSpin(_ u: Vec3, _ v: Vec3, _ angle: Double) -> (Vec3, Vec3) {
    let c = cos(angle)
    let s = sin(angle)
    return (
        (u.0 * c + v.0 * s, u.1 * c + v.1 * s, u.2 * c + v.2 * s),
        (v.0 * c - u.0 * s, v.1 * c - u.1 * s, v.2 * c - u.2 * s)
    )
}

/// The head frame, then the two eyes. Screen space: x right, y down, z towards the viewer.
/// Index 0 is the inner eye, index 1 the outer one.
nonisolated func bloubEyePoses(
    _ gaze: BloubGaze,
    _ scale: Double,
    _ split: Double = BloubFace.split
) -> (BloubEyePose, BloubEyePose) {
    var f: Vec3 = (0, 0, 1)
    var right: Vec3 = (1, 0, 0)
    var down: Vec3 = (0, 1, 0)

    (f, right) = bloubSpin(f, right, bloubDeg(gaze.yaw))
    (down, f) = bloubSpin(down, f, bloubDeg(gaze.pitch))
    (right, down) = bloubSpin(right, down, bloubDeg(gaze.roll))

    let frame = (f, right, down)
    func build(_ side: Double) -> BloubEyePose {
        let (ef, er) = bloubSpin(frame.0, frame.1, bloubDeg(split * side))
        return BloubEyePose(
            x: ef.0 * scale,
            y: ef.1 * scale,
            a: er.0,
            b: er.1,
            c: frame.2.0,
            d: frame.2.1,
            depth: ef.2
        )
    }
    return (build(-1), build(1))
}

/// Life at rest: slow gaze drift, saccades, blinks. A pure function of time, so pause, resume and
/// a jump to an arbitrary date always give the same picture. The values are offsets to add to the
/// current state's pose.
nonisolated struct BloubLiveliness {
    var dYaw: Double
    var dPitch: Double
    var dRoll: Double
    /// 1 = eye open, 0 = shut (a vertical squash in screen space)
    var lid: Double
    var driftX: Double
    var driftY: Double
    var breath: Double
}

/// The blink schedule is drawn once up to here and then repeats; an avatar's phase is drawn
/// from the same span.
nonisolated let bloubLifePeriod: Double = 900

/// Pre-drawn blink schedule: deterministic and stateless. Stops a second short of the period so
/// no blink is cut in half by the wrap.
nonisolated let bloubBlinks: [Double] = {
    var rng = BloubRng(seed: 0x5eed)
    var out: [Double] = []
    var t = 1.4
    while t < bloubLifePeriod - 1 {
        out.append(t)
        // 1.9 to 4.6 s apart, with the occasional double blink
        t += 1.9 + rng.next() * 2.7
        if rng.next() < 0.18 {
            out.append(t)
            t += 0.24
        }
    }
    return out
}()

/// Measured: 1 to 2 frames at 10 fps.
nonisolated private let bloubBlinkDuration = 0.18

/// The lid over one blink, `k` from 0 to 1: shuts fast, opens a little slower, both eased. A
/// linear lid reads as a camera shutter.
nonisolated func bloubLidCurve(_ k: Double) -> Double {
    func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }
    return k < 0.4 ? 1 - smooth(k / 0.4) : smooth((k - 0.4) / 0.6)
}

nonisolated private func bloubBlinkLid(_ t: Double) -> Double {
    let t = t.truncatingRemainder(dividingBy: bloubLifePeriod)
    for start in bloubBlinks {
        if t < start { break }
        let k = (t - start) / bloubBlinkDuration
        if k >= 0 && k <= 1 { return bloubLidCurve(k) }
    }
    return 1
}

/// How far a glance flicks the gaze, in degrees. Carved out of the slow sway's amplitude, not
/// added to it, so the drift's peak stays what `BloubEyefit` was fitted to: a wider box made the
/// fit fail on the narrow shapes for half the expressions.
nonisolated enum BloubGlance {
    static let yaw: Double = 2.5
    static let pitch: Double = 1.5
}

/// Pre-drawn glances: every few seconds the gaze flicks to a new spot in a tenth of a second and
/// holds it, the way eyes at rest jump rather than slide. Drawn short of the period so the wrap
/// lands on a held glance, never inside a flick.
nonisolated private let bloubGlances: [(at: Double, yaw: Double, pitch: Double)] = {
    var rng = BloubRng(seed: 0x91a2)
    var out: [(at: Double, yaw: Double, pitch: Double)] = []
    var t = 0.0
    while true {
        t += 1.5 + rng.next() * 3.5
        if t >= bloubLifePeriod - 1 { return out }
        out.append((t, (rng.next() * 2 - 1) * BloubGlance.yaw, (rng.next() * 2 - 1) * BloubGlance.pitch))
    }
}()

nonisolated private func bloubGlance(_ t: Double) -> (yaw: Double, pitch: Double) {
    let t = t.truncatingRemainder(dividingBy: bloubLifePeriod)
    var i = bloubGlances.count - 1
    while i >= 0 && bloubGlances[i].at > t { i -= 1 }
    // before the first glance of a period the last one of the previous period is still held
    let to = bloubGlances[i >= 0 ? i : bloubGlances.count - 1]
    let from = bloubGlances[i > 0 ? i - 1 : bloubGlances.count - 1]
    let k = i >= 0 ? BloubEase.outCubic(bloubClamp((t - to.at) / 0.1)) : 1
    return (bloubLerp(from.yaw, to.yaw, k), bloubLerp(from.pitch, to.pitch, k))
}

nonisolated func bloubLiveliness(
    _ t: Double,
    wander: Double = 1,
    blink: Bool = true,
    float: Bool = true
) -> BloubLiveliness {
    let glance = bloubGlance(t)
    // Periods coprime to each other, so the drift never visibly repeats.
    return BloubLiveliness(
        dYaw: (bloubLoopNoise(t, 11.3, 0.4) * (5.5 - BloubGlance.yaw) + bloubLoopNoise(t, 3.7, 2.1) * 1.6
            + glance.yaw) * wander,
        dPitch: (bloubLoopNoise(t, 9.1, 1.3) * (4.2 - BloubGlance.pitch) + bloubLoopNoise(t, 4.3, 0.7) * 1.3
            + glance.pitch) * wander,
        dRoll: bloubLoopNoise(t, 13.7, 3.2) * 2.2 * wander,
        lid: blink ? bloubBlinkLid(t) : 1,
        // At rest the video is almost still (centre stable to +-0.003, constant radius): all the
        // life is in the gaze and the blinks. Just enough left not to freeze the picture.
        driftX: float ? bloubLoopNoise(t, 7.9, 1.9) * 0.006 : 0,
        driftY: float ? bloubLoopNoise(t, 5.3, 0.3) * 0.007 : 0,
        // The width is constant; only the height breathes, very slightly.
        breath: float ? 1 + sin((t / 3.4) * .pi * 2) * 0.005 : 1
    )
}

/// A blink is a vertical squash in screen space about the eye's centre (measured: the bounding box
/// keeps its width and loses height down to ~0.35), not a shrink along the capsule's tilted axis.
/// So it composes after the tangent matrix and only touches the y outputs.
nonisolated func bloubBlinkScale(_ lid: Double) -> Double {
    0.06 + 0.94 * bloubClamp(lid)
}
