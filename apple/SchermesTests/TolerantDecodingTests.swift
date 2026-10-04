import Foundation
import Testing
@testable import Schermes

/// A newer daemon may send a value this build has never heard of. It must cost that one field,
/// never the whole page it arrived in.

private func decode<T: Decodable>(_ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

@Test func everyDaemonEnumTakesAValueItDoesNotKnow() throws {
    #expect(try decode([AgentState].self, #"["dreaming"]"#) == [.unknown])
    #expect(try decode([MessageRole].self, #"["system"]"#) == [.unknown])
    #expect(try decode([FeedbackRating].self, #"["meh"]"#) == [.unknown])
    #expect(try decode([EventType].self, #"["teleported"]"#) == [.unknown])
    #expect(try decode([ApprovalKind].self, #"["teleport"]"#) == [.action])
    #expect(try decode([TriggerState].self, #"["paused"]"#) == [.unknown])
    #expect(try decode([McpServerSummary.Transport].self, #"["sse"]"#) == [.unknown])

    #expect(try decode([NeedsYouKind].self, #"["new_kind"]"#) == [.other("new_kind")])
    #expect(try decode([NeedsYouAction].self, #"["new_action"]"#) == [.other("new_action")])
    #expect(try decode([RuleLevel].self, #"["new_level"]"#) == [.other("new_level")])
    #expect(try decode([CantUndoKind].self, #"["new_kind"]"#) == [.other("new_kind")])
    #expect(try decode([SearchKind].self, #"["new_kind"]"#) == [.other("new_kind")])
    #expect(try decode([TriggerKind].self, #"["new_kind"]"#) == [.other("new_kind")])
    #expect(try decode([IdlePassOutcome].self, #"["new_outcome"]"#) == [.other("new_outcome")])
    #expect(try decode([GoalStepState].self, #"["new_state"]"#) == [.other("new_state")])
    #expect(try decode([HelperKind].self, #"["new_kind"]"#) == [.other("new_kind")])
}

@Test func knownValuesStillDecodeAsThemselves() throws {
    #expect(try decode([AgentState].self, #"["using_computer","waiting_for_task_worker"]"#) == [.using_computer, .waiting_for_task_worker])
    #expect(try decode([MessageRole].self, #"["user","assistant","tool"]"#) == [.user, .assistant, .tool])
    #expect(try decode([ApprovalKind].self, #"["agent","conversation","action"]"#) == [.agent, .conversation, .action])
    #expect(try decode([McpServerSummary.Transport].self, #"["stdio","http"]"#) == [.stdio, .http])
}

@Test func aPageWithOneUnknownRoleStillDecodes() throws {
    let page: [Message] = try decode("""
    [
      {"id":1,"role":"user","content":"hi","createdAt":1757000000000},
      {"id":2,"role":"system","content":"from a newer daemon","createdAt":1757000001000},
      {"id":3,"role":"assistant","content":"hello","createdAt":1757000002000,
       "feedback":{"rating":"meh"}}
    ]
    """)
    #expect(page.map(\.role) == [.user, .unknown, .assistant])
    #expect(page[2].feedback?.rating == .unknown)
}

@Test func anAgentInAStateFromANewerDaemonStillLists() throws {
    let agents: [Agent] = try decode("""
    [{"id":1,"name":"alpha","display":1,"state":"hibernating","createdAt":1757000000000}]
    """)
    #expect(agents.first?.state == .unknown)
    #expect(agents.first?.state.busy == false)
}

@Test func anUnknownTransportIsNeverSentBack() throws {
    let draft = McpServerDraft(name: "odd", transport: .unknown)
    #expect(throws: EncodingError.self) { try JSONEncoder().encode(draft) }
}

@Test func anExpiredScreenshotSaysSo() throws {
    let message: Message = try decode("""
    {"id":4,"role":"tool","content":"","createdAt":1757000000000,
     "image":{"mediaType":"image/png","base64":"","expired":true}}
    """)
    #expect(message.image?.expired == true)
    #expect(message.image?.base64.isEmpty == true)

    let fresh: Base64Image = try decode(#"{"mediaType":"image/png","base64":"iVBO"}"#)
    #expect(fresh.expired == nil)
    let sent = String(decoding: try JSONEncoder().encode(fresh), as: UTF8.self)
    #expect(!sent.contains("expired"))
}
