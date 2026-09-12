import Foundation

/// A port of the bloub avatar engine (`github.com/jeremy-prt/bloub`, MIT, commit
/// `b4bb3c1b5f93c7b87a2e8d620f667c4093d97749`). The measured constants are kept as they are there,
/// and `BloubEngine.sample` stays a pure function of time, so a frozen board and a running avatar
/// draw the same picture.
nonisolated enum Bloub {
    /// Radius of the resting ball, in viewBox units. Every other measurement is a fraction of it.
    static let radius: Double = 100

    /// Half the displayed viewBox. The orbit rings and the comet swoosh reach 1.4 radii; keeping
    /// them under this is hand tuning of the seed tables, and a test holds it.
    static let halfViewBox: Double = 158

    static let profileSamples = 64
}

nonisolated let bloubTau = Double.pi * 2

nonisolated func bloubClamp(_ v: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double {
    v < lo ? lo : (v > hi ? hi : v)
}

nonisolated func bloubLerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
}

/// Measured off the reference video: transitions are exponential ease-outs with no overshoot of
/// the body. The only springs are local, and are written into the state that owns them.
nonisolated enum BloubEase {
    static func outCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    static func inOutCubic(_ t: Double) -> Double {
        t < 0.5 ? 4 * pow(t, 3) : 1 - pow(-2 * t + 2, 3) / 2
    }
    static func outQuint(_ t: Double) -> Double { 1 - pow(1 - t, 5) }
}

/// Periodic 1D noise, seamless over `period`. Drives the gaze drift.
nonisolated func bloubLoopNoise(_ t: Double, _ period: Double, _ seed: Double = 0) -> Double {
    let p = (t / period) * bloubTau
    return 0.55 * sin(p + seed)
        + 0.3 * sin(2 * p + seed * 1.7 + 1.1)
        + 0.15 * sin(3 * p + seed * 2.3 + 2.4)
}

/// mulberry32, bit for bit as JavaScript runs it: the seeded tables below are only reproducible
/// if the truncating 32-bit arithmetic is too.
nonisolated struct BloubRng {
    private var a: UInt32

    init(seed: UInt32) { a = seed }

    mutating func next() -> Double {
        a = a &+ 0x6d2b_79f5
        var t = (a ^ (a >> 15)) &* (1 | a)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}
