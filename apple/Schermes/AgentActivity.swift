import Foundation
#if os(iOS)
import ActivityKit
#endif

/// The Live Activity of one agent's turn, compiled into the app and the widget extension. The
/// daemon writes both parts as JSON (`LiveActivityAttributes`/`LiveActivityState` in `shared`)
/// and ActivityKit decodes them with a default decoder: the property names are the wire keys.
nonisolated struct AgentActivityAttributes: Codable, Hashable, Sendable {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        var title: String
        var stepsDone: Int
        var stepsTotal: Int
        var needsYou: Int
        /// An `AgentState` raw value, kept a string so a state this build does not know still shows.
        var state: String
    }

    var agent: String
    var label: String
    var look: String?

    var identity: BloubIdentity {
        look.flatMap(BloubIdentity.init(token:)) ?? .standard(for: agent)
    }
}

#if os(iOS)
extension AgentActivityAttributes: ActivityAttributes {}
#endif
