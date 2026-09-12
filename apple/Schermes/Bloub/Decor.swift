import CoreGraphics
import Foundation

/// The rings are not flat colours: the video shows a full hue wheel at constant lightness, with a
/// gradient along each stroke. Measured: S 45-62 %, L 50-67 %.
nonisolated func bloubWheel(_ hue: Double, _ s: Double = 0.55, _ l: Double = 0.62) -> BloubRGB {
    var h = hue.truncatingRemainder(dividingBy: 360)
    if h < 0 { h += 360 }
    let c = (1 - abs(2 * l - 1)) * s
    let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
    let m = l - c / 2
    let rgb: (Double, Double, Double) =
        switch h {
        case ..<60: (c, x, 0)
        case ..<120: (x, c, 0)
        case ..<180: (0, c, x)
        case ..<240: (0, x, c)
        case ..<300: (x, 0, c)
        default: (c, 0, x)
        }
    // Rounded per channel, as bloub goes through a hex string here.
    let byte = { (v: Double) in ((v + m) * 255).rounded() / 255 }
    return BloubRGB(r: byte(rgb.0), g: byte(rgb.1), b: byte(rgb.2))
}

nonisolated struct BloubDot {
    var x: Double
    var y: Double
    var r: Double
    var opacity: Double
    /// Depth haze: 0 melts into the paper, 1 is the body colour at full strength. Mixed at draw
    /// time, which is the only place the chosen colour is known.
    var depth: Double?
    /// A non-circular shape, in ball radii and centred on the origin (the tilted "!" has a
    /// teardrop, not a disc). When it is there, `r` no longer draws the dot.
    var teardrop: Bool = false
    /// rotation applied to the teardrop, degrees
    var rot: Double = 0
}

/// What a state declares. The arc geometry stays in ball radii; the engine, the only thing that
/// knows the viewBox scale, rasterises it.
nonisolated struct BloubArcSpec {
    var id: String
    var seed: BloubArcSeed
    var t: Double
    var opacity: Double
}

nonisolated struct BloubArcRender {
    var id: String
    /// the part in front of the body
    var front: [[CGPoint]]
    /// the part behind it, drawn first so the silhouette hides it
    var back: [[CGPoint]]
    var width: Double
    var opacity: Double
    var gradientStart: CGPoint
    var gradientEnd: CGPoint
    var stops: [BloubRGB]
}

nonisolated struct BloubArcSeed {
    /// semi-major axis, in ball radii
    var a: Double
    /// flattening b/a: measured <= 0.45, the orbit planes are seen almost edge on
    var k: Double
    /// tilt of the major axis on screen, radians
    var tilt: Double
    /// turns per second
    var speed: Double
    var phase: Double
    /// fraction of the turn actually drawn
    var sweep: Double
    var hue: Double
    var hueSpan: Double
    var width: Double
    var cx: Double
    var cy: Double
}

/// Projects a tilted 3D circle orthographically.
///
/// The circle lives in the plane spanned by u (in the screen) and v (which dives into depth). The
/// z component cuts the arc in two: the back half is drawn before the body, so the body hides it.
/// That real depth sort is what makes the rings read as orbits rather than as a flat drawing.
nonisolated func bloubArcRender(
    _ seed: BloubArcSeed,
    _ t: Double,
    _ scale: Double,
    _ id: String,
    _ opacity: Double = 1
) -> BloubArcRender {
    let spin = seed.phase + t * seed.speed * bloubTau
    let cu = cos(seed.tilt)
    let su = sin(seed.tilt)
    let kz = (max(0, 1 - seed.k * seed.k)).squareRoot()

    let n = 64
    let span = seed.sweep * bloubTau
    var front: [[CGPoint]] = []
    var back: [[CGPoint]] = []
    var prev: Bool?

    for i in 0...n {
        let th = spin + (Double(i) / Double(n)) * span
        let ct = cos(th)
        let st = sin(th)
        // u = (cos tilt, sin tilt, 0) ; v = (-sin tilt * k, cos tilt * k, kz)
        let x = seed.a * (ct * cu + st * -su * seed.k) + seed.cx
        let y = seed.a * (ct * su + st * cu * seed.k) + seed.cy
        let z = seed.a * st * kz

        let behind = z < 0
        let point = CGPoint(x: x * scale, y: y * scale)
        let starts = behind != prev
        if behind {
            if starts { back.append([]) }
            back[back.count - 1].append(point)
        } else {
            if starts { front.append([]) }
            front[front.count - 1].append(point)
        }
        prev = behind
    }

    let gx = cos(seed.tilt) * seed.a * scale
    let gy = sin(seed.tilt) * seed.a * scale
    return BloubArcRender(
        id: id,
        front: front,
        back: back,
        width: seed.width * scale,
        opacity: opacity,
        gradientStart: CGPoint(x: seed.cx * scale - gx, y: seed.cy * scale - gy),
        gradientEnd: CGPoint(x: seed.cx * scale + gx, y: seed.cy * scale + gy),
        stops: [
            bloubWheel(seed.hue),
            bloubWheel(seed.hue + seed.hueSpan * 0.5),
            bloubWheel(seed.hue + seed.hueSpan)
        ]
    )
}

nonisolated enum BloubDecor {
    /// 6 rings, semi-major 1.30-1.40 (so clearly bigger than the ball), flattening always <= 0.45,
    /// thickness 0.055, ~3.3 turns a second.
    static let rings: [BloubArcSeed] = {
        var rng = BloubRng(seed: 0xa11ce)
        return (0..<6).map { i in
            BloubArcSeed(
                a: 1.3 + rng.next() * 0.1,
                k: 0.05 + rng.next() * 0.4,
                tilt: (Double(i) / 6) * .pi + rng.next() * 0.5,
                speed: 3 + rng.next() * 0.7,
                phase: rng.next() * bloubTau,
                sweep: 0.6 + rng.next() * 0.25,
                hue: (Double(i) * 360) / 6 + rng.next() * 30,
                hueSpan: 60 + rng.next() * 60,
                width: 0.05 + rng.next() * 0.012,
                cx: 0,
                cy: 0.1
            )
        }
    }()

    /// A bundle of nested arcs sweeping across the triangle just before the orbits. Seen almost
    /// edge on, hence the hairpin shape; rmax 1.37.
    static let swoosh: [BloubArcSeed] = (0..<4).map { index in
        let i = Double(index)
        return BloubArcSeed(
            a: 0.78 + i * 0.2,
            k: 0.05 + i * 0.02,
            tilt: -0.62 + i * 0.05,
            speed: 0.3,
            phase: 0.06 * i,
            sweep: 0.4,
            hue: 95 + i * 62,
            hueSpan: 100,
            width: 0.05,
            cx: 0,
            cy: -0.12
        )
    }

    /// Measured x: -0.557 / -0.013 / +0.532, y = 0.
    static let dotX: [Double] = [-0.557, -0.013, 0.532]
    static let dotR: Double = 0.165
    static let dotPeak: Double = 1.25

    /// 5 particles, a new one every 0.2 s, lifetime 0.55 s.
    private static let particleSeeds: [(birth: Double, angle: Double, rho: Double)] = {
        var rng = BloubRng(seed: 0xbeef)
        return (0..<5).map { i in
            (birth: Double(i) * 0.2, angle: rng.next() * bloubTau, rho: 0.58 + rng.next() * 0.18)
        }
    }()

    /// The particles do not fly off in a straight line: they spiral inwards (radius x0.75 a frame,
    /// angle +100 deg/s) while growing, and pass behind the core where they are swallowed.
    static func particles(_ t: Double, _ scale: Double) -> [BloubDot] {
        var out: [BloubDot] = []
        for p in particleSeeds {
            let u = t - p.birth
            if u < 0 || u > 0.62 { continue }
            let rho = p.rho * pow(0.75, u * 10)
            let a = p.angle + (u * 100 * .pi) / 180
            out.append(BloubDot(
                x: cos(a) * rho * scale,
                y: sin(a) * rho * scale,
                r: (0.04 + 0.028 * bloubClamp(u / 0.55)) * scale,
                opacity: bloubClamp(u / 0.06) * bloubClamp((0.62 - u) / 0.08),
                depth: bloubClamp(1 - rho / 0.8)
            ))
        }
        return out
    }

    /// Counter-intuitively the dot does not cross the screen: it stays centred and the trail
    /// orbits it. Ellipse a = 0.85, b = 0.15, major axis tilted +34 degrees, 4 ribbons, ~210 deg/s.
    static let cometRibbons: [BloubArcSeed] = {
        var rng = BloubRng(seed: 0xc0e7)
        return (0..<4).map { i in
            let d = Double(i) - 1.5
            return BloubArcSeed(
                a: 0.85 * (1 + d * 0.03),
                // the same flattening to within 5 %: the ribbons make one tight bundle
                k: (0.15 / 0.85) * (1 + d * 0.16),
                tilt: (34 * .pi) / 180 + d * 0.035,
                speed: 210 / 360,
                // measured phase offset: 10 to 20 degrees between ribbons, no more
                phase: -Double(i) * 0.045 + rng.next() * 0.012,
                sweep: 0.34,
                hue: Double(i) * 85 + rng.next() * 20,
                hueSpan: 80,
                width: 0.095,
                cx: 0,
                cy: 0
            )
        }
    }()

    /// Radius of the comet's dot, measured at 0.129.
    static let cometDot: Double = 0.129

    /// Blue read off the pixels.
    static let notifBlue = BloubRGB(hex: 0x2496e8)
    /// The badge sits exactly on the circumference, at -42 degrees.
    static let notifAngle: Double = -42
    static let notifDistance: Double = 1.003
    /// Resting radius; the pop peaks 14 % above it.
    static let notifR: Double = 0.15
    static let notifPop: Double = 1.14
    /// The notch is a disc concentric with the badge, subtracted from the body. The margin is
    /// constant (0.054 R) and follows the body's scale.
    static let notifMargin: Double = 0.054
}
