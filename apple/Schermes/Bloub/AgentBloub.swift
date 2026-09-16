import Foundation
import Observation

/// What an agent's state looks like on its avatar.
///
/// One table, on purpose: taste can move an entry without touching anything else, and the switch
/// is exhaustive so a new `AgentState` cannot ship without a face.
extension AgentState {
    var bloub: BloubStateId {
        switch self {
        case .thinking: .thinking
        case .using_computer: .orbit
        case .using_terminal: .comet
        case .waiting_for_user: .idle
        case .waiting_for_agent, .waiting_for_task_worker: .wide
        case .failed: .exclaim
        case .completed: .sleep
        case .idle: .idle
        }
    }
}

extension BloubStateId {
    /// The stretch of a clip that plays again while an agent stays in its state. `orbit` plays
    /// once and settles into a plain ball, and a tool call outlasts it. The rest of the table
    /// holds its own pose (`wide`, `notify`, `exclaim`, `idle`, `comet`) or loops by itself
    /// (`thinking`, `sleep`). The pair was measured against the clip: the pose at the end is the
    /// pose at the start.
    nonisolated var heldLoop: ClosedRange<Double>? {
        switch self {
        // One turn of the triangle, so the body is exact and the gaze 0.74 degrees off.
        // ponytail: the rings spin at their own speeds, so at the wrap they skip up to 153 degrees
        // and the last one dims to half. Cross-fading two frames in the view is the upgrade.
        case .orbit: 0.81...1.61
        default: nil
        }
    }

    /// How far the pointer can swing this face's gaze, as a share of `BloubLook.followTurn`; nil
    /// where it cannot. Only faces whose eyes hold still follow: thinking, failed and completed
    /// show no eyes at all, and orbit and comet fly them round the ball as the clip. `wide` and
    /// `notify` have the biggest eyes, and on a capsule or a triangle the full swing puts them
    /// through the edge wherever the face is placed.
    nonisolated var pointerReach: Double? {
        switch self {
        case .idle, .swirl: 1
        case .notify: 0.6
        case .wide: 0.2
        default: nil
        }
    }
}

nonisolated extension BloubLook {
    /// The furthest the pointer turns the face away from the viewer, in degrees. The resting face
    /// is already turned 39.5, so this stays within what every shape has room for.
    static let followTurn: Double = 32

    /// Where an avatar looks while it follows the pointer. `nx` and `ny` point from the avatar to
    /// the pointer, y down as on screen, at most 1 long; the length is how far the face turns, up
    /// to `followTurn`. The angles invert `bloubEyePoses`, so the face's normal lands exactly on
    /// the pointer's direction: the eyes look AT the pointer, not somewhere above it.
    /// `BloubEyefit` solves the face's placement over the whole ring at full turn.
    static func following(nx: Double, ny: Double) -> BloubLook {
        let d = hypot(nx, ny)
        guard d > 1e-9 else { return BloubLook(yaw: 0, pitch: 0, mix: 1, wander: 0) }
        let turn = min(d, 1) * followTurn * .pi / 180
        let x = sin(turn) * nx / d
        let y = sin(turn) * ny / d
        return BloubLook(
            yaw: atan2(x, cos(turn)) * 180 / .pi,
            pitch: -asin(y) * 180 / .pi,
            mix: 1,
            wander: 0
        )
    }
}

/// Drives one avatar's engine for as long as its agent holds a state. The engine plays a clip once,
/// and `setState` ignores the state it is already in, so a held clip is moved back round its
/// `heldLoop` with `reset`; the engine itself stays a pure function of time. Under Reduce Motion
/// nothing replays.
nonisolated final class BloubPlayer {
    let engine: BloubEngine
    private var clipStart: Double = 0
    private var following = false

    /// Slower than the follow itself: a pointer leaving the window should not snap the eyes home.
    static let lookRelease: Double = 0.6

    init(state: BloubStateId, shape: BloubShapeId?, phase: Double = 0) {
        engine = BloubEngine(state: state, shape: shape, expression: .neutral, phase: phase)
    }

    func setState(_ id: BloubStateId, now: Double) {
        guard id != engine.state else { return }
        engine.setState(id, now: now)
        clipStart = now
    }

    func setShape(_ id: BloubShapeId?, now: Double) {
        engine.setShape(id, now: now)
    }

    /// `aim` is the pointer as `BloubLook.following` reads it, nil when there is none.
    func sample(_ now: Double, reduceMotion: Bool, aim: CGPoint? = nil) -> BloubFrame {
        let clip = now - clipStart
        if !reduceMotion, let loop = engine.state.heldLoop, clip >= loop.upperBound {
            let length = loop.upperBound - loop.lowerBound
            clipStart += length * ((clip - loop.lowerBound) / length).rounded(.down)
            engine.reset(engine.state, now: clipStart)
        }
        if let aim, let reach = engine.state.pointerReach {
            engine.setLook(.following(nx: aim.x * reach, ny: aim.y * reach), now: now)
            following = true
        } else if following {
            engine.setLook(nil, now: now, morph: Self.lookRelease)
            following = false
        }
        return engine.sample(now, decorStill: reduceMotion)
    }
}

/// An agent's look: a body shape and a colour from bloub's catalogue. Stored on the daemon as
/// `Agent.look`, in the `token` form, so every device draws the same avatar; kept locally too,
/// so the list has a look before the first poll answers.
struct BloubIdentity: Codable, Equatable, Sendable {
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

/// `@Observable` cannot see `Self` in a stored-property initializer, so the key is file level.
private let agentLooksKey = "agentLooks"

/// Every agent's look, stored locally. Reading one that was never chosen gives the deterministic
/// default rather than nothing, so a caller never has to handle an agent it has not met.
@Observable
final class AgentLooks {
    @ObservationIgnored private let defaults: UserDefaults
    private var stored: [String: BloubIdentity]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stored = defaults.data(forKey: agentLooksKey)
            .flatMap { try? JSONDecoder().decode([String: BloubIdentity].self, from: $0) } ?? [:]
    }

    subscript(name: String) -> BloubIdentity {
        get { stored[name] ?? .standard(for: name) }
        set {
            guard stored[name] != newValue else { return }
            stored[name] = newValue
            if let data = try? JSONEncoder().encode(stored) {
                defaults.set(data, forKey: agentLooksKey)
            }
        }
    }

    /// What the daemon holds for each agent, applied over the local copy: the daemon is where a
    /// choice made on another device arrives. An agent with no token keeps what this device has.
    func adopt(_ agents: [Agent]) {
        for agent in agents {
            if let token = agent.look, let identity = BloubIdentity(token: token) {
                self[agent.name] = identity
            }
        }
    }
}
