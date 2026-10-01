import Foundation

/// Straight 8-bit colour. The engine has no opinion about how a platform spells a colour, so the
/// arcs and the particle haze mix here and the view converts once.
nonisolated struct BloubRGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hex: UInt32) {
        r = Double((hex >> 16) & 255) / 255
        g = Double((hex >> 8) & 255) / 255
        b = Double(hex & 255) / 255
    }

    /// Lower-case `#rrggbb`, the spelling bloub's own values are written in.
    var hex: String {
        let byte = { (v: Double) in String(format: "%02x", Int((v * 255).rounded())) }
        return "#\(byte(r))\(byte(g))\(byte(b))"
    }

    static func mix(_ from: BloubRGB, _ to: BloubRGB, _ t: Double) -> BloubRGB {
        // Rounded per channel, as bloub mixes through hex strings.
        let channel = { (a: Double, b: Double) in
            ((a * 255 + (b * 255 - a * 255) * t).rounded()) / 255
        }
        return BloubRGB(r: channel(from.r, to.r), g: channel(from.g, to.g), b: channel(from.b, to.b))
    }
}

/// The customiser's shapes. Unlike the animation silhouettes these are not read off the video:
/// they are built analytically from the original customiser's grid. Two deliberately separate
/// sources — the animated states stay faithful to the video, the base shape is the owner's choice.
nonisolated enum BloubShapeId: String, CaseIterable, Codable, Sendable {
    case circle, pebble, squircle, capsule, triangle, hexagon, cloud, droplet

    var radii: [Double] {
        switch self {
        case .circle: BloubTables.circle
        case .pebble: BloubTables.pebble
        case .squircle: BloubTables.squircle
        case .capsule: BloubTables.capsule
        case .triangle: BloubTables.triangle
        case .hexagon: BloubTables.hexagon
        case .cloud: BloubTables.cloud
        case .droplet: BloubTables.droplet
        }
    }
}

/// The original customiser's palette.
nonisolated enum BloubColorId: String, CaseIterable, Codable, Sendable {
    case ink, brown, red, orange, amber, green, teal, blue, violet, pink, grey, cream

    var rgb: BloubRGB {
        switch self {
        case .ink: BloubRGB(hex: 0x0a0a0c)
        case .brown: BloubRGB(hex: 0x8b5e3c)
        case .red: BloubRGB(hex: 0xe8483f)
        case .orange: BloubRGB(hex: 0xf08a24)
        case .amber: BloubRGB(hex: 0xf0b429)
        case .green: BloubRGB(hex: 0x3ecf8e)
        case .teal: BloubRGB(hex: 0x2fbfa0)
        case .blue: BloubRGB(hex: 0x3b93f0)
        case .violet: BloubRGB(hex: 0x8b5cf6)
        case .pink: BloubRGB(hex: 0xe152b0)
        case .grey: BloubRGB(hex: 0xa3a3a3)
        case .cream: BloubRGB(hex: 0xf1efe9)
        }
    }
}

/// An agent's look: a body shape and a colour from bloub's catalogue. Stored on the daemon as
/// `Agent.look`, in the `token` form, so every device draws the same avatar; kept locally too,
/// so the list has a look before the first poll answers.
nonisolated struct BloubIdentity: Codable, Equatable, Sendable {
    var shape: BloubShapeId
    var color: BloubColorId

    /// The daemon's opaque form: `shape:colour`. A token from a newer catalogue that this build
    /// cannot read is left alone rather than overwritten, so `init` is failable.
    var token: String { "\(shape.rawValue):\(color.rawValue)" }

    init(shape: BloubShapeId, color: BloubColorId) {
        self.shape = shape
        self.color = color
    }

    init?(token: String) {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let shape = BloubShapeId(rawValue: parts[0]),
              let color = BloubColorId(rawValue: parts[1])
        else { return nil }
        self.init(shape: shape, color: color)
    }

    /// The look an agent has before anyone picks one. Derived from the name, so an agent seen for
    /// the first time already looks like itself and still does after a relaunch — `hashValue` is
    /// seeded per process and would not. Shape and colour are read off different parts of the same
    /// hash, so the two do not move together.
    static func standard(for name: String) -> BloubIdentity {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        let shapes = BloubShapeId.allCases
        let colors = BloubColorId.allCases
        return BloubIdentity(
            shape: shapes[Int(hash % UInt64(shapes.count))],
            color: colors[Int((hash / UInt64(shapes.count)) % UInt64(colors.count))]
        )
    }
}
