import Foundation
import Testing
@testable import Schermes

/// The strings `daemon/src/push.test.ts` pins its Live Activity payload to. ActivityKit decodes
/// with a plain `JSONDecoder`, so decoding them here is what the widget does with a push.
private let stateJSON = #"{"title":"Ship the site","stepsDone":1,"stepsTotal":3,"needsYou":2,"state":"thinking"}"#
private let attributesJSON = #"{"agent":"alpha","label":"Alpha","look":"cloud:teal"}"#

@Test func liveActivityDecodesTheDaemonsContentState() throws {
    let state = try JSONDecoder().decode(AgentActivityAttributes.ContentState.self, from: Data(stateJSON.utf8))
    #expect(state == .init(title: "Ship the site", stepsDone: 1, stepsTotal: 3, needsYou: 2, state: "thinking"))
}

@Test func liveActivityAttributesCarryTheLookOrFallBackToTheStandardOne() throws {
    let attributes = try JSONDecoder().decode(AgentActivityAttributes.self, from: Data(attributesJSON.utf8))
    #expect(attributes.agent == "alpha")
    #expect(attributes.label == "Alpha")
    #expect(attributes.identity == BloubIdentity(shape: .cloud, color: .teal))

    let bare = try JSONDecoder().decode(AgentActivityAttributes.self, from: Data(#"{"agent":"beta","label":"beta"}"#.utf8))
    #expect(bare.identity == .standard(for: "beta"))
}
