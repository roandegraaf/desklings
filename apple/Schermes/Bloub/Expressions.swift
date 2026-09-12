import Foundation

/// The bot's resting expression.
///
/// The face is two capsules, so everything happens on four levers: the head's orientation, the eye
/// separation, the eye proportions, and each eye's own tilt. That last one is what makes anger and
/// sadness possible: they need mirrored tilts, which a head roll cannot give — it tips both eyes
/// the same way. Only the resting state carries an expression; the video's expressive states keep
/// their own, which is the thing being reproduced.
nonisolated enum BloubExpressionId: String, CaseIterable, Codable, Sendable {
    case neutral, attentive, surprised, excited, happy, laughing, angry, sad
    case scared, wary, confused, curious, proud, shy, bored, sleepy
}

nonisolated struct BloubExpression {
    var id: BloubExpressionId?
    var gaze: BloubGaze
    var split: Double
    var eyes: (BloubEyeCfg, BloubEyeCfg)
}

/// `tilt` is in degrees, positive tips the top of the capsule to the right.
nonisolated private func eye(_ w: Double, _ h: Double, _ tilt: Double = 0, _ open: Double = 1) -> BloubEyeCfg {
    BloubEyeCfg(w: w, h: h, open: open, tilt: tilt)
}

/// Both eyes alike, tilts mirrored when a tilt is given.
nonisolated private func pair(
    _ w: Double,
    _ h: Double,
    _ tilt: Double = 0,
    _ open: Double = 1
) -> (BloubEyeCfg, BloubEyeCfg) {
    (eye(w, h, tilt, open), eye(w, h, -tilt, open))
}

nonisolated extension BloubExpressionId {
    var expression: BloubExpression {
        switch self {
        // the pose read frame by frame off the reference video
        case .neutral:
            BloubExpression(
                id: self, gaze: BloubFace.restGaze, split: BloubFace.split,
                eyes: (eye(BloubFace.eyeWidth, BloubFace.eyeHeight),
                       eye(BloubFace.eyeWidth, BloubFace.eyeHeight))
            )
        case .attentive:
            BloubExpression(id: self, gaze: BloubGaze(yaw: 4, pitch: 5, roll: -4), split: 16,
                            eyes: pair(0.21, 0.44))
        case .surprised:
            BloubExpression(id: self, gaze: BloubGaze(yaw: 3, pitch: -3, roll: 0), split: 19,
                            eyes: pair(0.45, 0.47))
        case .excited:
            BloubExpression(id: self, gaze: BloubGaze(yaw: 6, pitch: -14, roll: 0), split: 19.5,
                            eyes: pair(0.4, 0.56, -10))
        // eyes squeezed into arcs: the tops converge slightly
        case .happy:
            BloubExpression(id: self, gaze: BloubGaze(yaw: 5, pitch: 9, roll: 0), split: 17,
                            eyes: pair(0.27, 0.17, 14))
        case .laughing:
            BloubExpression(id: self, gaze: BloubGaze(yaw: 4, pitch: 14, roll: 0), split: 18,
                            eyes: pair(0.34, 0.13, 20))
        // tops converging hard towards the centre, and narrowed eyes
        case .angry:
            BloubExpression(id: self, gaze: BloubGaze(yaw: 3, pitch: 7, roll: 0), split: 17,
                            eyes: pair(0.34, 0.15, 30))
        // the reverse: the tops diverge, and the gaze falls
        case .sad:
            BloubExpression(id: self, gaze: BloubGaze(yaw: 3, pitch: -13, roll: 0), split: 16,
                            eyes: pair(0.22, 0.4, -28))
        case .scared:
            BloubExpression(id: self, gaze: BloubGaze(yaw: 2, pitch: -20, roll: 0), split: 20.5,
                            eyes: pair(0.4, 0.6))
        // one eye plainly more shut than the other
        case .wary:
            BloubExpression(id: self, gaze: BloubGaze(yaw: 12, pitch: 6, roll: -6), split: 16,
                            eyes: (eye(0.21, 0.4), eye(0.22, 0.15)))
        // asymmetric on both axes: mismatched sizes AND tilts. The narrowed eye is deliberately
        // flat (ratio 1.6): near a ratio of 1 it would read as round and its tilt would not show.
        case .confused:
            BloubExpression(id: self, gaze: BloubGaze(yaw: -14, pitch: 3, roll: 8), split: 16.5,
                            eyes: (eye(0.2, 0.44, -18), eye(0.28, 0.17, 14)))
        // the head tips: the roll is what carries the curiosity
        case .curious:
            BloubExpression(id: self, gaze: BloubGaze(yaw: 16, pitch: -9, roll: -15), split: 16.5,
                            eyes: (eye(0.24, 0.46, -8), eye(0.2, 0.38, -8)))
        case .proud:
            BloubExpression(id: self, gaze: BloubGaze(yaw: 5, pitch: 17, roll: 0), split: 17,
                            eyes: pair(0.3, 0.15, 18))
        case .shy:
            BloubExpression(id: self, gaze: BloubGaze(yaw: -19, pitch: -14, roll: -7), split: 14,
                            eyes: pair(0.17, 0.3))
        // horizontal slits and a gaze that wanders off to the side
        case .bored:
            BloubExpression(id: self, gaze: BloubGaze(yaw: -22, pitch: 2, roll: 0), split: 16,
                            eyes: pair(0.3, 0.12))
        // half-dropped lids: through `open`, so the same screen-space squash as a blink
        case .sleepy:
            BloubExpression(id: self, gaze: BloubGaze(yaw: 6, pitch: -9, roll: -3), split: 16,
                            eyes: pair(0.2, 0.42, 0, 0.42))
        }
    }
}

/// Interpolates two expressions: a change slides rather than jumps.
nonisolated func bloubBlendExpression(
    _ a: BloubExpression,
    _ b: BloubExpression,
    _ t: Double
) -> BloubExpression {
    BloubExpression(
        id: b.id,
        gaze: BloubGaze(
            yaw: bloubLerp(a.gaze.yaw, b.gaze.yaw, t),
            pitch: bloubLerp(a.gaze.pitch, b.gaze.pitch, t),
            roll: bloubLerp(a.gaze.roll, b.gaze.roll, t)
        ),
        split: bloubLerp(a.split, b.split, t),
        eyes: (
            BloubEyeCfg.lerp(a.eyes.0, b.eyes.0, t),
            BloubEyeCfg.lerp(a.eyes.1, b.eyes.1, t)
        )
    )
}
