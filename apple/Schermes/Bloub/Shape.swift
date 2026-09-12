import CoreGraphics
import Foundation

/// A body outline: a radial profile r(theta) plus a pose.
///
/// Every profile is sampled at the same angles, so any two shapes have points that correspond one
/// to one and morphing is a linear interpolation of radii. That is what makes the transitions
/// clean without a path-morphing library.
nonisolated struct BloubSilhouette: Equatable {
    var radii: [Double]
    /// profile rotation, radians
    var rot: Double = 0
    /// centre offset, in ball radii
    var cx: Double = 0
    var cy: Double = 0
    /// squash and stretch, applied in screen space after the rotation
    var sx: Double = 1
    var sy: Double = 1
}

nonisolated enum BloubGeometry {
    static let angles: [Double] = (0..<Bloub.profileSamples).map {
        Double($0) / Double(Bloub.profileSamples) * bloubTau
    }
    static let cosines: [Double] = angles.map(cos)
    static let sines: [Double] = angles.map(sin)

    /// A perfect circle: the neutral base (dot, bubble, fade target).
    static func circle(_ radius: Double) -> BloubSilhouette {
        BloubSilhouette(radii: [Double](repeating: radius, count: Bloub.profileSamples))
    }

    static func blend(_ a: BloubSilhouette, _ b: BloubSilhouette, _ t: Double) -> BloubSilhouette {
        var radii = [Double](repeating: 0, count: Bloub.profileSamples)
        for i in 0..<Bloub.profileSamples {
            radii[i] = bloubLerp(a.radii[i], b.radii[i], t)
        }
        // Shortest way round, so going from +170 to -170 degrees does not spin a full turn.
        var dRot = b.rot - a.rot
        while dRot > .pi { dRot -= bloubTau }
        while dRot < -.pi { dRot += bloubTau }
        return BloubSilhouette(
            radii: radii,
            rot: a.rot + dRot * t,
            cx: bloubLerp(a.cx, b.cx, t),
            cy: bloubLerp(a.cy, b.cy, t),
            sx: bloubLerp(a.sx, b.sx, t),
            sy: bloubLerp(a.sy, b.sy, t)
        )
    }

    /// Projects the silhouette to screen points. `scale` is the ball radius in viewBox units.
    static func points(_ s: BloubSilhouette, _ scale: Double) -> [CGPoint] {
        let cr = cos(s.rot)
        let sr = sin(s.rot)
        var out = [CGPoint](repeating: .zero, count: Bloub.profileSamples)
        for i in 0..<Bloub.profileSamples {
            let r = s.radii[i]
            let x = r * cosines[i]
            let y = r * sines[i]
            let rx = x * cr - y * sr
            let ry = x * sr + y * cr
            out[i] = CGPoint(x: (rx * s.sx + s.cx) * scale, y: (ry * s.sy + s.cy) * scale)
        }
        return out
    }

    /// The profile's radius in an arbitrary direction, interpolated between the two neighbouring
    /// samples. Used to pull whatever sits *on* the body back onto a non-circular outline: an eye
    /// placed at 0.62 radii leaves a shape whose edge is at 0.55 in that direction, and the mask
    /// crops it.
    static func radius(_ radii: [Double], at angle: Double) -> Double {
        let n = radii.count
        let t = (angle / bloubTau).truncatingRemainder(dividingBy: 1).adding1AndWrap() * Double(n)
        let i = Int(floor(t))
        return bloubLerp(radii[i % n], radii[(i + 1) % n], t - floor(t))
    }
}

nonisolated private extension Double {
    /// JavaScript's `((x % 1) + 1) % 1`: a fraction in [0, 1) whatever the sign.
    func adding1AndWrap() -> Double {
        (self + 1).truncatingRemainder(dividingBy: 1)
    }
}
