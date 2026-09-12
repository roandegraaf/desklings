import Foundation
import Testing
@testable import Schermes

/// The daemon's own wire shapes, decoded into the Swift mirror of `shared/src/index.ts`.

private func decode<T: Decodable>(_ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private func encode(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

@Test func healthDecodes() throws {
    let health: HealthResponse = try decode(#"{"status":"ok","setupRequired":true}"#)
    #expect(health.status == "ok")
    #expect(health.setupRequired)
}

@Test func anAgentDecodesWithAndWithoutAParent() throws {
    let agents: [Agent] = try decode("""
    [
      {"id":1,"name":"alpha","display":1,"state":"idle","createdAt":1757000000000},
      {"id":2,"name":"alpha-w1","display":1001,"state":"completed","parentId":1,
       "parentConversationId":7,"createdAt":1757000001000}
    ]
    """)
    #expect(agents.count == 2)
    #expect(agents[0].parentId == nil)
    #expect(agents[0].state == .idle)
    #expect(agents[1].parentId == 1)
    #expect(agents[1].parentConversationId == 7)
    #expect(agents[1].state == .completed)
}

@Test func everyAgentStateOnTheWireDecodes() throws {
    for state in AgentState.allCases {
        let agent: Agent = try decode(
            #"{"id":1,"name":"a","display":1,"state":"\#(state.rawValue)","createdAt":0}"#
        )
        #expect(agent.state == state)
    }
}

@Test func aTurnDecodesWithItsToolCallsAndResults() throws {
    let messages: [Message] = try decode("""
    [
      {"id":1,"role":"user","content":"take a look","createdAt":1757000000000},
      {"id":2,"role":"assistant","content":"",
       "toolCalls":[{"id":"call-1","name":"screenshot","arguments":"{}"}],
       "createdAt":1757000001000},
      {"id":3,"role":"tool","content":"screenshot taken","toolCallId":"call-1",
       "createdAt":1757000002000},
      {"id":4,"role":"user","content":"","sender":"bravo",
       "image":{"mediaType":"image/png","base64":"iVBORw0KGgo="},
       "createdAt":1757000003000}
    ]
    """)

    #expect(messages.map(\.role) == [.user, .assistant, .tool, .user])
    #expect(messages[0].sender == nil)
    #expect(messages[1].toolCalls?.first?.id == "call-1")
    #expect(messages[1].toolCalls?.first?.arguments == "{}")
    #expect(messages[2].toolCallId == "call-1")
    #expect(messages[3].sender == "bravo")
    #expect(messages[3].image?.mediaType == "image/png")
    #expect(Data(base64Encoded: messages[3].image?.base64 ?? "") != nil)
}

@Test func theLiveReplyDecodesAndKnowsWhenItIsNothing() throws {
    let empty: LiveReply = try decode(#"{"text":"","reasoning":""}"#)
    #expect(empty.isEmpty)
    let writing: LiveReply = try decode(#"{"text":"on it","reasoning":"looking"}"#)
    #expect(!writing.isEmpty)
    #expect(writing.text == "on it")
}

@Test func theErrorEnvelopeDecodes() throws {
    let envelope: ApiError = try decode(#"{"error":"no such agent"}"#)
    #expect(envelope.error == "no such agent")
}

@Test func settingsDecodeAsOneBodyAndAnUpdateLeavesOutWhatItDoesNotChange() throws {
    let provider: ProviderSettings = try decode("""
    {"baseUrl":"https://api.example.com/v1","model":"m","apiKeySet":true,"extraBody":""}
    """)
    #expect(provider.apiKeySet)

    let web: WebSettings = try decode(#"{"searchUrl":"","searchKeySet":false}"#)
    #expect(web.searchUrl.isEmpty)

    // A blank key must be left out, not sent as "": the daemon writes whatever it is given.
    let update = ProviderSettingsUpdate(baseUrl: "https://x/v1", model: "m")
    let sent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(update))
    #expect((sent as? [String: Any])?.keys.sorted() == ["baseUrl", "model"])
}

@Test func anMcpSummaryDecodesForBothTransports() throws {
    let servers: [McpServerSummary] = try decode("""
    [
      {"name":"files","transport":"stdio","command":"npx server","secretKeys":["TOKEN"]},
      {"name":"remote","transport":"http","url":"https://mcp.example.com","secretKeys":[]}
    ]
    """)
    #expect(servers[0].transport == .stdio)
    #expect(servers[0].url == nil)
    #expect(servers[1].transport == .http)
    #expect(servers[1].command == nil)

    let result: McpTestResult = try decode(#"{"ok":false,"tools":[],"error":"refused"}"#)
    #expect(!result.ok)
    #expect(result.error == "refused")
}

@Test func aScheduleDecodesBeforeAndAfterItHasFired() throws {
    let schedules: [Schedule] = try decode("""
    [
      {"id":1,"agent":"alpha","cron":"0 9 * * *","prompt":"check the inbox","paused":false,
       "nextRunAt":1757000000000,"createdAt":1756000000000},
      {"id":2,"agent":"alpha","cron":"*/5 * * * *","prompt":"poll","paused":true,
       "nextRunAt":1757000600000,"lastRunAt":1757000300000,"createdAt":1756000000000}
    ]
    """)
    #expect(schedules[0].lastRunAt == nil)
    #expect(schedules[1].paused)
    #expect(schedules[1].lastRunAt == 1757000300000)
}

@Test func anExecutionEventKeepsWhateverJsonItsDataCarries() throws {
    let events: [ExecutionEvent] = try decode("""
    [
      {"id":1,"type":"state","data":{"from":"idle","to":"thinking"},"createdAt":1757000000000},
      {"id":2,"type":"control","data":{"held":true},"createdAt":1757000001000},
      {"id":3,"type":"tool_call","data":{"name":"scroll","args":{"amount":3},"tags":["a","b"],
       "note":null},"createdAt":1757000002000}
    ]
    """)
    #expect(events[0].type == .state)
    #expect(events[0].data["to"] == JSONValue.string("thinking"))
    #expect(events[1].data["held"] == JSONValue.bool(true))
    #expect(events[2].data["args"] == JSONValue.object(["amount": .number(3)]))
    #expect(events[2].data["tags"] == JSONValue.array([.string("a"), .string("b")]))
    #expect(events[2].data["note"] == JSONValue.null)
}

@Test func aConversationDecodes() throws {
    let conversations: [Conversation] = try decode("""
    [{"id":1,"participants":["alpha"],"createdAt":1757000000000},
     {"id":2,"participants":["alpha","bravo"],"createdAt":1757000001000}]
    """)
    #expect(conversations[0].participants == ["alpha"])
    #expect(conversations[1].participants.count == 2)
}

@Test func computerActionsAndResultsRoundTripOnTheWire() throws {
    let click = ComputerAction(action: .click, x: 10, y: 20, button: 1)
    #expect(try encode(click) == #"{"action":"click","button":1,"x":10,"y":20}"#)

    let scroll = ComputerAction(action: .scroll, x: 5, y: 6, direction: .down, amount: 3)
    #expect(try encode(scroll)
            == #"{"action":"scroll","amount":3,"direction":"down","x":5,"y":6}"#)

    let result: ComputerResult = try decode("""
    {"action":"screenshot","image":{"mediaType":"image/png","base64":"iVBORw0KGgo="}}
    """)
    #expect(result.action == .screenshot)
    #expect(result.text == nil)

    let command: CommandResult = try decode("""
    {"exitCode":0,"stdout":"hi","stderr":"","timedOut":false,"background":false}
    """)
    #expect(command.exitCode == 0)
    #expect(!command.timedOut)
}

@Test func aMessageWindowBecomesTheQueryTheDaemonExpects() throws {
    let client = SchermesClient(baseURL: URL(string: "http://127.0.0.1:7777")!)

    #expect(try client.messagesURL(.agent("alpha"), .newest).absoluteString
            == "http://127.0.0.1:7777/api/agents/alpha/messages")
    #expect(try client.messagesURL(.agent("alpha"), MessageWindow(before: 42)).absoluteString
            == "http://127.0.0.1:7777/api/agents/alpha/messages?before=42")
    #expect(try client.messagesURL(.agent("alpha"), MessageWindow(after: 7, limit: CATCH_UP)).absoluteString
            == "http://127.0.0.1:7777/api/agents/alpha/messages?after=7&limit=200")
    // A name is typed, so it is escaped rather than trusted to be `^[a-z0-9][a-z0-9-]{0,30}$`.
    #expect(try client.messagesURL(.agent("a/b"), .newest).absoluteString
            == "http://127.0.0.1:7777/api/agents/a%2Fb/messages")
    // A shared thread is the same window on a different route.
    #expect(try client.messagesURL(.conversation(9), .newest).absoluteString
            == "http://127.0.0.1:7777/api/conversations/9/messages")
    #expect(try client.messagesURL(.conversation(9), MessageWindow(limit: 1)).absoluteString
            == "http://127.0.0.1:7777/api/conversations/9/messages?limit=1")
}
