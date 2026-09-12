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
        case .waiting_for_user: .notify
        case .waiting_for_agent, .waiting_for_task_worker: .wide
        case .failed: .exclaim
        case .completed: .sleep
        case .idle: .idle
        }
    }
}

extension BloubStateId {
    /// The stretch of a clip that plays again while an agent stays in its state. `comet` and
    /// `orbit` play once and settle into a plain ball, and a tool call outlasts them. The rest of
    /// the table holds its own pose (`wide`, `notify`, `exclaim`, `idle`) or loops by itself
    /// (`thinking`, `sleep`). Each pair was measured against the clip: the pose at the end is the
    /// pose at the start.
    nonisolated var heldLoop: ClosedRange<Double>? {
        switch self {
        // Eyes and ribbons are out of sight at both ends; the dot is 0.002 radii off.
        case .comet: 0.029...2.0
        // One turn of the triangle, so the body is exact and the gaze 0.74 degrees off.
        // ponytail: the rings spin at their own speeds, so at the wrap they skip up to 153 degrees
        // and the last one dims to half. Cross-fading two frames in the view is the upgrade.
        case .orbit: 0.81...1.61
        default: nil
        }
    }
}

/// Drives one avatar's engine for as long as its agent holds a state. The engine plays a clip once,
/// and `setState` ignores the state it is already in, so a held clip is moved back round its
/// `heldLoop` with `reset`; the engine itself stays a pure function of time. Under Reduce Motion
/// nothing replays.
nonisolated final class BloubPlayer {
    let engine: BloubEngine
    private var clipStart: Double = 0

    init(state: BloubStateId, shape: BloubShapeId?) {
        engine = BloubEngine(state: state, shape: shape, expression: .neutral)
    }

    func setState(_ id: BloubStateId, now: Double) {
        guard id != engine.state else { return }
        engine.setState(id, now: now)
        clipStart = now
    }

    func setShape(_ id: BloubShapeId?, now: Double) {
        engine.setShape(id, now: now)
    }

    func sample(_ now: Double, reduceMotion: Bool) -> BloubFrame {
        let clip = now - clipStart
        if !reduceMotion, let loop = engine.state.heldLoop, clip >= loop.upperBound {
            let length = loop.upperBound - loop.lowerBound
            clipStart += length * ((clip - loop.lowerBound) / length).rounded(.down)
            engine.reset(engine.state, now: clipStart)
        }
        return engine.sample(now, decorStill: reduceMotion)
    }
}

/// An agent's look: a body shape and a colour from bloub's catalogue. The daemon has no field for
/// either, so it lives in the app, keyed by agent name.
struct BloubIdentity: Codable, Equatable, Sendable {
    var shape: BloubShapeId
    var color: BloubColorId

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
            stored[name] = newValue
            if let data = try? JSONEncoder().encode(stored) {
                defaults.set(data, forKey: agentLooksKey)
            }
        }
    }
}
