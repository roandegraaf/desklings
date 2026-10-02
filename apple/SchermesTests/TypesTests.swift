import Foundation
import Testing
import UserNotifications
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

@Test func aLiveReplyWaitingToRetryIsNotNothing() throws {
    let waiting: LiveReply = try decode(#"""
    {"text":"","reasoning":"","retry":{"attempt":2,"of":5,"retryAt":1000,"error":"provider returned HTTP 429: slow down","model":"Main","backup":"Spare"}}
    """#)
    #expect(!waiting.isEmpty)
    #expect(waiting.retry?.attempt == 2)
    #expect(waiting.retry?.backup == "Spare")
    let alone: RetryState = try decode(#"{"attempt":5,"of":5,"retryAt":0,"error":"HTTP 503","model":"Main"}"#)
    #expect(alone.backup == nil)
}

@Test func theRetryCardCountsDownAndThenSaysNow() {
    let retry = RetryState(attempt: 3, of: 5, retryAt: 10_000, error: "", model: "Main", backup: nil)
    #expect(RetryCard.headline(retry, now: Date(timeIntervalSince1970: 1.5)) == "Main is busy. Trying again in 9 s, attempt 3 of 5")
    #expect(RetryCard.headline(retry, now: Date(timeIntervalSince1970: 11)) == "Main is busy. Trying again now, attempt 3 of 5")
}

@Test func aRefusedKeyDecodesWithItsSettingsAction() throws {
    let item: NeedsYouItem = try decode(#"""
    {"id":"provider-auth:3","kind":"provider_auth","agent":"mo","conversationId":2,"title":"Main refused its key","detail":"provider returned HTTP 401: bad key","createdAt":5,"actions":["settings"]}
    """#)
    #expect(item.kind == .providerAuth)
    #expect(item.actions == [.settings])
    #expect(try encode(item.kind) == #""provider_auth""#)
    #expect(try encode(NeedsYouAction.settings) == #""settings""#)
    #expect(item.presentation.word == "Needs you · key refused")
}

@Test func theErrorEnvelopeDecodes() throws {
    let envelope: ApiError = try decode(#"{"error":"no such agent"}"#)
    #expect(envelope.error == "no such agent")
}

@Test func webSettingsDecode() throws {
    let web: WebSettings = try decode(#"{"searchUrl":"","searchKeySet":false}"#)
    #expect(web.searchUrl.isEmpty)
}

@Test func aModelEntryDecodesWithItsBadges() throws {
    let models: [ModelEntry] = try decode("""
    [{"id":1,"name":"Fast","baseUrl":"https://api.example.com/v1","model":"m","apiKeySet":true,
      "extraBody":"","isDefault":true,"isBackup":false,"createdAt":0}]
    """)
    #expect(models.first?.name == "Fast")
    #expect(models.first?.isDefault == true && models.first?.isBackup == false)
    #expect(models.first?.providerId == nil, "a daemon from before providers still decodes")
}

@Test func anAgentsModelIsAbsentForTheDefault() throws {
    let plain: Agent = try decode(#"{"id":1,"name":"mo","display":1,"state":"idle","createdAt":0}"#)
    #expect(plain.modelId == nil)
    let assigned: Agent = try decode(#"{"id":1,"name":"mo","display":1,"state":"idle","createdAt":0,"modelId":3}"#)
    #expect(assigned.modelId == 3)
}

@Test func aModelPickSendsNullRatherThanNothing() throws {
    #expect(try encode(modelPick(nil)) == #"{"id":null}"#)
    #expect(try encode(modelPick(3)) == #"{"id":3}"#)
}

@Test func aModelEditSendsOnlyWhatChanged() throws {
    let entry = ModelEntry(
        id: 1, name: "Fast", providerId: 2, providerName: "Acme", baseUrl: "https://x/v1", model: "m",
        apiKeySet: true, extraBody: #"{"a":1}"#, isDefault: true, isBackup: false, createdAt: 0
    )
    var draft = ModelDraft(entry)
    #expect(draft.update(from: entry) == ModelUpdate())

    draft.name = "Quick"
    #expect(try encode(draft.update(from: entry)) == #"{"name":"Quick"}"#)

    draft.extraBody = ""
    #expect(draft.update(from: entry) == ModelUpdate(name: "Quick", extraBody: ""))

    draft.providerId = 3
    #expect(draft.update(from: entry).providerId == 3)

    var fresh = ModelDraft(providerId: 2)
    fresh.name = "Local"
    fresh.model = "qwen"
    #expect(fresh.update(from: nil) == ModelUpdate(name: "Local", providerId: 2, model: "qwen"))
}

@Test func aProviderEditSendsOnlyWhatChangedAndNeverABlankKey() throws {
    let entry = ProviderEntry(id: 2, name: "Acme", baseUrl: "https://x/v1", apiKeySet: true, createdAt: 0)
    var draft = ProviderDraft(entry)
    #expect(draft.update(from: entry) == ProviderUpdate())

    draft.apiKey = "sk-new"
    #expect(try encode(draft.update(from: entry)) == #"{"apiKey":"sk-new"}"#)

    var fresh = ProviderDraft()
    fresh.name = "Local"
    fresh.baseUrl = " http://localhost:11434/v1 "
    #expect(fresh.update(from: nil) == ProviderUpdate(name: "Local", baseUrl: "http://localhost:11434/v1"))
}

@Test func anMcpSummaryDecodesForBothTransports() throws {
    let servers: [McpServerSummary] = try decode("""
    [
      {"name":"files","transport":"stdio","command":"npx","args":["server"],"secretKeys":["TOKEN"]},
      {"name":"remote","transport":"http","url":"https://mcp.example.com","secretKeys":[]}
    ]
    """)
    #expect(servers[0].transport == .stdio)
    #expect(servers[0].url == nil)
    #expect(servers[0].args == ["server"])
    #expect(servers[1].transport == .http)
    #expect(servers[1].command == nil && servers[1].args == nil)

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
    #expect(try client.messagesURL(.agent("alpha"), MessageWindow(limit: 1, images: false)).absoluteString
            == "http://127.0.0.1:7777/api/agents/alpha/messages?limit=1&images=0")
}

@Test func approvalsDecodeBothDeletionsAndActions() throws {
    let listed: [Approval] = try decode("""
    [{"id":1,"agent":"mo","conversationId":2,"kind":"agent","category":"delete_files","target":"juno","participants":[],"reason":"done","createdAt":0},
     {"id":2,"agent":"mo","conversationId":2,"kind":"action","category":"spend_money","target":"NS","amount":"EUR 42","origin":"ns.nl","participants":[],"reason":"train","createdAt":0}]
    """)
    #expect(listed.map(\.kind) == [.agent, .action])
    #expect(listed[0].amount == nil)
    #expect(listed[1].category == "spend_money")
    #expect(listed[1].amount == "EUR 42")
    #expect(listed[1].origin == "ns.nl")
}

@Test func needsYouKeepsKindsAndActionsItDoesNotKnow() throws {
    let listed: [NeedsYouItem] = try decode("""
    [{"id":"approval:1","kind":"approval","agent":"mo","conversationId":2,"title":"Asks to spend money","detail":"train",
      "approval":{"id":1,"agent":"mo","conversationId":2,"kind":"action","category":"spend_money","target":"NS","participants":[],"reason":"train","createdAt":0},
      "createdAt":0,"actions":["approve","always","deny"]},
     {"id":"handover:9","kind":"handover","agent":"juno","conversationId":3,"title":"Take the screen","createdAt":1,"actions":["take","open"]},
     {"id":"failure:7","kind":"failure","agent":"scout","conversationId":4,"title":"Could not finish its turn","messageId":7,"createdAt":2,"actions":["retry","open"]}]
    """)
    #expect(listed.map(\.kind) == [.approval, .other("handover"), .failure])
    #expect(listed[0].approval?.category == "spend_money")
    #expect(listed[0].actions == [.approve, .always, .deny])
    #expect(listed[1].actions == [.other("take"), .open])
    #expect(listed[2].messageId == 7)
    #expect(try encode(listed[1].kind) == #""handover""#)
}

@Test func agentRulesDecodeAndKeepAnUnknownLevel() throws {
    let rules: AgentRules = try decode("""
    {"levels":{"browse":"on_its_own","send_messages":"if_pre_approved","spend_money":"ask_first",
     "passwords_security":"hand_to_you","share_outside":"only_on_tuesdays"},
     "preApproved":{"send_messages":["flytap.com"]}}
    """)
    #expect(rules.levels["browse"] == .onItsOwn)
    #expect(rules.levels["send_messages"] == .ifPreApproved)
    #expect(rules.levels["spend_money"] == .askFirst)
    #expect(rules.levels["passwords_security"] == .handToYou)
    #expect(rules.levels["share_outside"] == .other("only_on_tuesdays"))
    #expect(rules.preApproved == ["send_messages": ["flytap.com"]])
}

@Test func aRulesUpdateSendsOnlyWhatChanged() throws {
    #expect(try encode(AgentRulesUpdate(levels: ["spend_money": .askFirst])) == #"{"levels":{"spend_money":"ask_first"}}"#)
    #expect(try encode(AgentRulesUpdate(preApproved: ["spend_money": ["a.com"]])) == #"{"preApproved":{"spend_money":["a.com"]}}"#)
}

@Test func ruleRowsFollowTheDaemonsCategoriesWithPasswordsLocked() {
    let daemon = [
        "browse", "run_commands", "write_files", "delete_files", "send_messages",
        "spend_money", "install_software", "share_outside",
    ]
    #expect(RuleRow.editable(runsAs: "mo").map(\.category) == daemon)
    #expect(RuleRow.locked.category == "passwords_security")
    #expect(RuleRow.editable(runsAs: "mo")[1].hint.contains("mo"))
    #expect(Set(RuleLevel.ladder.map(\.word)).count == 4)
    #expect(RuleLevel.ladder.map(\.raw) == ["on_its_own", "if_pre_approved", "ask_first", "hand_to_you"])
}

@Test func aHungBrowserDecodesWithItsThreeWaysOut() throws {
    let item: NeedsYouItem = try decode(#"""
    {"id":"browser:9","kind":"browser_hung","agent":"mo","conversationId":2,"title":"Its browser stopped answering","messageId":9,"createdAt":5,"actions":["screen","restart_desktop","restart_browser"]}
    """#)
    #expect(item.kind == .browserHung)
    #expect(item.actions == [.screen, .restartDesktop, .restartBrowser])
    #expect(try encode(item.kind) == #""browser_hung""#)
    #expect(try encode(NeedsYouAction.restartDesktop) == #""restart_desktop""#)
    #expect(item.presentation.word == "Needs you · browser stuck")
    #expect(item.actions.sorted { $0.order < $1.order }.first == .screen, "the quiet way out first")
}

@Test func aHandOverDecodesWithTakeTheScreen() throws {
    let item: NeedsYouItem = try decode(#"""
    {"id":"hands:7","kind":"hand_over","agent":"mo","conversationId":2,"title":"Asks you to take the screen","detail":"Solve the CAPTCHA.","messageId":7,"createdAt":5,"actions":["open","take_screen"]}
    """#)
    #expect(item.kind == .handOver)
    #expect(item.actions == [.open, .takeScreen])
    #expect(try encode(item.kind) == #""hand_over""#)
    #expect(try encode(NeedsYouAction.takeScreen) == #""take_screen""#)
    #expect(item.presentation.word == "Needs you · hands")
    #expect(item.actions.sorted { $0.order < $1.order }.last == .takeScreen, "the go-ahead last")
}

@Test func controlStateDecodesWithAndWithoutAHandOver() throws {
    let plain: SchermesClient.ControlState = try decode(#"{"held":true}"#)
    #expect(plain.held && plain.handOver == nil)
    let asked: SchermesClient.ControlState = try decode(#"{"held":false,"handOver":true}"#)
    #expect(!asked.held && asked.handOver == true)
}

@Test func controlStateCarriesARecordingOnlyWhileOneRuns() throws {
    let plain: SchermesClient.ControlState = try decode(#"{"held":true,"handOver":false}"#)
    #expect(plain.recording == nil)
    let live: SchermesClient.ControlState = try decode(#"{"held":true,"handOver":false,"recording":{"startedAt":5,"steps":3,"shots":2,"secret":true}}"#)
    #expect(live.recording == SchermesClient.RecordingState(startedAt: 5, steps: 3, shots: 2, secret: true))
    let cut: SchermesClient.ControlState = try decode(#"{"held":true,"recording":{"startedAt":5,"steps":200,"shots":12,"secret":false,"truncated":true}}"#)
    #expect(cut.recording?.truncated == true)
}

@Test func aFormRequestDecodesWithItsFields() throws {
    let item: NeedsYouItem = try decode(#"""
    {"id":"form:3","kind":"form","agent":"mo","conversationId":2,"title":"Asks you to fill a form on https://bank.example","detail":"Log in.","messageId":9,
     "form":{"id":3,"origin":"https://bank.example","secure":true,"reason":"Log in.","createdAt":5,
       "fields":[{"id":"ab-0","label":"Email","type":"email","autocomplete":"username","required":true,"secret":false,"saved":true},
                 {"id":"ab-1","label":"Password","type":"password","required":true,"secret":true,"saved":false},
                 {"id":"ab-2","label":"Country","type":"select","required":false,"options":[{"value":"nl","label":"Netherlands"}],"secret":false,"saved":false}],
       "unfillable":[{"label":"CAPTCHA","reason":"captcha"}]},
     "createdAt":5,"actions":["fill","take_screen"]}
    """#)
    #expect(item.kind == .form)
    #expect(item.actions == [.fill, .takeScreen])
    #expect(try encode(item.kind) == #""form""#)
    #expect(try encode(NeedsYouAction.fill) == #""fill""#)
    #expect(item.presentation.word == "Needs you · form")
    let form = try #require(item.form)
    #expect(form.fields.map(\.secret) == [false, true, false])
    #expect(form.fields.first?.saved == true && form.fields.first?.autocomplete == "username")
    #expect(form.fields.last?.options?.first?.label == "Netherlands")
    #expect(form.unfillable == [UnfillableField(label: "CAPTCHA", reason: "captcha")])
}

private func field(_ id: String, type: String = "text", autocomplete: String? = nil, secret: Bool = false, saved: Bool = false) -> FormField {
    FormField(id: id, label: id, type: type, autocomplete: autocomplete, required: false, options: nil, secret: secret, saved: saved)
}

@Test func formFieldsGetTheirContentTypeFromAutocompleteThenType() {
    #expect(field("a", type: "email", autocomplete: "username").content == .username)
    #expect(field("a", type: "email").content == .email)
    #expect(field("a", autocomplete: "section-login email").content == .email)
    #expect(field("a", type: "password", autocomplete: "current-password").content == .password)
    #expect(field("a", type: "password", autocomplete: "new-password").content == .newPassword)
    #expect(field("a", type: "password").content == .password)
    #expect(field("a", autocomplete: "one-time-code").content == .oneTimeCode)
    #expect(field("a", type: "tel").content == .phone)
    #expect(field("a", type: "url").content == .url)
    #expect(field("a").content == .plain)
    #expect(field("a", type: "password", secret: true).hidesTyping)
    #expect(field("a", autocomplete: "new-password", secret: true).hidesTyping)
    #expect(!field("a", autocomplete: "one-time-code", secret: true).hidesTyping, "two secure fields read as a sign-up")
    #expect(!field("a").hidesTyping)
}

@Test func aFillSendsOnlyWhatTheOwnerEntered() throws {
    let fields = [
        field("user", saved: true), field("pass", type: "password", saved: true), field("note"),
        field("country", type: "select"), field("plan", type: "radio"),
        field("terms", type: "checkbox"), field("news", type: "checkbox"),
    ]
    let fill = FormFill(
        fields: fields,
        draft: ["user": "", "pass": "hunter22", "country": "", "terms": "false", "stray": "x"],
        remember: true
    )
    #expect(fill.values == ["pass": "hunter22", "country": "", "terms": "false"], "blank saved text left out, choices kept, untouched boxes left out")
    #expect(try encode(fill) == #"{"remember":true,"values":{"country":"","pass":"hunter22","terms":"false"}}"#)
    #expect(FormFill(fields: fields, draft: [:], remember: false).values.isEmpty)
}

@Test func aReplyCarriesTheOwnersFeedback() throws {
    let rated: Message = try decode(
        #"{"id":4,"role":"assistant","content":"hi","sender":"mo","feedback":{"rating":"down","reason":"vague"},"createdAt":0}"#
    )
    #expect(rated.feedback == MessageFeedback(rating: .down, reason: "vague"))
    let plain: Message = try decode(#"{"id":5,"role":"assistant","content":"hi","createdAt":0}"#)
    #expect(plain.feedback == nil)
    let answer: FeedbackAnswer = try decode(#"{"feedback":null}"#)
    #expect(answer.feedback == nil)
}

@Test func aFeedbackClearSendsNullRatherThanNothing() throws {
    #expect(try encode(FeedbackUpdate(rating: nil)) == #"{"rating":null}"#)
    #expect(try encode(FeedbackUpdate(rating: .up)) == #"{"rating":"up"}"#)
    #expect(try encode(FeedbackUpdate(rating: .down, reason: "vague")) == #"{"rating":"down","reason":"vague"}"#)
}

@Test func idleSettingsDecodeAndTheUpdateSendsNullOnlyWhenPicked() throws {
    let settings: IdleSettings = try decode(#"""
    {"enabled":false,"conditions":["new_messages","someday_new"],"dailyTokens":200000,"turnCap":20,
     "modelId":null,"startHour":1,"endHour":6,"pausedReason":"The owner dismissed 3 notes in a row."}
    """#)
    #expect(settings.conditions == ["new_messages", "someday_new"])
    #expect(settings.modelId == nil)
    #expect(settings.pausedReason == "The owner dismissed 3 notes in a row.")

    #expect(try encode(IdleSettingsUpdate(modelId: .some(nil))) == #"{"modelId":null}"#)
    #expect(try encode(IdleSettingsUpdate(modelId: 3)) == #"{"modelId":3}"#)
    #expect(try encode(IdleSettingsUpdate(turnCap: 5)) == #"{"turnCap":5}"#)
}

@Test func idlePassesDecodeEveryOutputKindAndKeepUnknownOnes() throws {
    let passes: [IdlePass] = try decode(#"""
    [{"id":1,"agent":"mo","startedAt":10,"matched":[],"outcome":"skipped","tokens":0,"endedAt":10,"reason":null,"outputs":[]},
     {"id":2,"agent":"juno","startedAt":11,"matched":["memory_size"],"outcome":"ran","tokens":900,"endedAt":20,"reason":null,
      "outputs":[
        {"id":1,"createdAt":12,"resolved":null,"kind":"memory","before":"a\nb","after":"a\nc"},
        {"id":2,"createdAt":13,"resolved":"accepted","kind":"routine","cron":"0 7 * * *","prompt":"fetch invoices"},
        {"id":3,"createdAt":14,"resolved":null,"kind":"note","text":"the sheet is stale"},
        {"id":4,"createdAt":15,"resolved":null,"kind":"cleanup","approvalId":9},
        {"id":5,"createdAt":16,"resolved":null,"kind":"trigger","anything":1}]},
     {"id":3,"agent":"pixel","startedAt":12,"matched":["new_messages"],"outcome":"due","tokens":0,"endedAt":null,
      "reason":"the daily token budget is spent","outputs":[]},
     {"id":4,"agent":"pixel","startedAt":13,"matched":["new_messages"],"outcome":"later","tokens":0,"endedAt":null,"reason":null,"outputs":[]}]
    """#)
    #expect(passes[0].summary == "Had nothing new, so it didn't run, 0 tokens.")
    #expect(passes[1].summary == nil)
    #expect(passes[1].outputs.map(\.kind) == [
        .memory(before: "a\nb", after: "a\nc"),
        .routine(cron: "0 7 * * *", prompt: "fetch invoices"),
        .note(text: "the sheet is stale"),
        .cleanup(approvalId: 9),
        .other("trigger"),
    ])
    #expect(passes[1].outputs[1].resolvedWord == "Turned on")
    #expect(passes[2].summary == "Didn't run: the daily token budget is spent.")
    #expect(passes[3].outcome == .other("later"))
}

@Test func aWastedPassReadsAsNothingFound() throws {
    let pass: IdlePass = try decode(#"""
    {"id":1,"agent":"mo","startedAt":1,"matched":["new_messages"],"outcome":"wasted","tokens":5,"endedAt":2,"reason":null,"outputs":[]}
    """#)
    #expect(pass.summary == "Looked, found nothing.")
}

@Test func theMemoryDiffListsRemovedThenAddedLinesAndSkipsBlanks() {
    let diff = memoryDiff(before: "# Memory\nold line\n\nkept", after: "# Memory\n\nkept\nnew one\nnew two")
    #expect(diff == [
        DiffLine(added: false, text: "old line"),
        DiffLine(added: true, text: "new one"),
        DiffLine(added: true, text: "new two"),
    ])
}

@Test func anIdleOutputActionGoesOutAsItsWord() throws {
    #expect(try encode(["action": IdleOutputAction.undo]) == #"{"action":"undo"}"#)
}

@Test func triggersDecodeEveryKindWithoutALogin() throws {
    let listed: [Trigger] = try decode(#"""
    [{"id":1,"agent":"mo","kind":"webhook","config":{},"reason":"Build on push.","state":"on","maxPerHour":6,"dropped":2,"lastFiredAt":5,"lastError":null,"createdAt":1,"webhook":{"path":"/hooks/abc","secret":"s3"}},
     {"id":2,"agent":"mo","kind":"imap","config":{"host":"imap.mail.test","port":993,"mailbox":"INBOX","everyMinutes":5},"reason":"Invoices.","state":"proposed","maxPerHour":6,"dropped":0,"lastFiredAt":null,"lastError":"connect ECONNREFUSED","createdAt":2,"hasLogin":false},
     {"id":3,"agent":"mo","kind":"folder","config":{"path":"Downloads","everyMinutes":5},"reason":"r","state":"off","maxPerHour":6,"dropped":0,"lastFiredAt":null,"createdAt":3},
     {"id":4,"agent":"mo","kind":"calendar","config":{},"reason":"r","state":"proposed","maxPerHour":6,"dropped":0,"lastFiredAt":null,"lastError":null,"createdAt":4}]
    """#)
    #expect(listed.map(\.kind) == [.webhook, .imap, .folder, .other("calendar")])
    #expect(listed[0].webhook == TriggerWebhook(path: "/hooks/abc", secret: "s3"))
    #expect(listed[0].watches == "/hooks/abc")
    #expect(listed[1].needsLogin)
    #expect(listed[1].watches == "INBOX on imap.mail.test")
    #expect(listed[1].lastError == "connect ECONNREFUSED")
    #expect(listed[2].watches == "~/Downloads")
    #expect(listed[2].lastError == nil)
    #expect(!listed[2].needsLogin)
    #expect(try encode(["action": TriggerAction.delete]) == #"{"action":"delete"}"#)
    #expect(triggerSender == "Trigger")
}

@Test func aLoginItemCarriesItsTrigger() throws {
    let item: NeedsYouItem = try decode(#"""
    {"id":"form:9","kind":"form","agent":"mo","conversationId":1,"title":"Needs the login for INBOX on imap.mail.test","triggerId":2,"createdAt":1,"actions":["fill"]}
    """#)
    #expect(item.triggerId == 2)
    #expect(item.actions == [.fill])
}

@Test func aGoalDecodesAndKeepsStepStatesAndHelperKindsItDoesNotKnow() throws {
    let goals: [Goal] = try decode("""
    [{"id":3,"title":"Lisbon trip","lead":"mo","state":"open",
      "steps":[{"text":"Compare flights","owner":"mo","state":"done"},
               {"text":"Hold hotels","owner":"mo-g3-1","state":"doing"},
               {"text":"Book it","owner":"mo","state":"waiting"},
               {"text":"Calendar","owner":"mo","state":"blocked"}],
      "results":["flights.xlsx"],"nextFromYou":["Approve the payment"],
      "helpers":[{"name":"mo-g3-1","kind":"agent","reason":"own cookies","state":"thinking","createdAt":1},
                 {"name":"mo-w","kind":"worker","reason":"its own screen","state":"completed","keptAt":5,"createdAt":2},
                 {"name":"mo-x","kind":"robot","reason":"new","state":"idle","createdAt":3}],
      "createdAt":0,"updatedAt":4}]
    """)
    let goal = try #require(goals.first)
    #expect(goal.steps.map(\.state) == [.done, .doing, .other("waiting"), .blocked])
    #expect(goal.helpers.map(\.kind) == [.agent, .worker, .other("robot")])
    #expect(goal.helpers.map(\.canBeKept) == [true, false, false])
    #expect(goal.temporaryHelpers.map(\.name) == ["mo-g3-1", "mo-x"])
    #expect(goal.involves("mo") && goal.involves("mo-g3-1") && !goal.involves("mo-w"))
    #expect(try encode(goal.steps[2].state) == #""waiting""#)

    let item: NeedsYouItem = try decode("""
    {"id":"goal:3","kind":"goal","agent":"mo","conversationId":1,"title":"Next from you: Lisbon trip","goalId":3,"createdAt":0,"actions":["open"]}
    """)
    #expect(item.kind == .goal)
    #expect(item.goalId == 3)
}

@Test func theGoalRingIsDoneStepsOverAllSteps() {
    func goal(_ states: [GoalStepState]) -> Goal {
        Goal(id: 1, title: "t", lead: "mo", state: "open",
             steps: states.map { GoalStep(text: "s", owner: "mo", state: $0) },
             results: [], nextFromYou: [], helpers: [], createdAt: 0, updatedAt: 0)
    }
    #expect(goal([]).progress == 0)
    #expect(goal([.done, .done, .doing, .todo, .blocked, .other("waiting")]).progress == 2.0 / 6)
    #expect(goal([.done, .done, .doing, .todo, .blocked, .other("waiting")]).progressWords == "2 of 6")
    #expect(goal([.done]).progress == 1)
}

@Test func searchAnswerDecodesUnknownKindsAndMissingFields() throws {
    let answer: SearchAnswer = try decode(#"""
    {"understoodAs":["PDF","by Ledger"],"byModel":false,
     "filters":{"kinds":["file","hologram"],"words":["pdf"]},
     "hits":[
      {"kind":"file","agent":"ledger","path":"~/tap/a.pdf","at":5,"snippet":"~/tap/a.pdf"},
      {"kind":"message","conversationId":3,"participants":["ledger"],"messageId":9,"at":4,"snippet":"hi"},
      {"kind":"screenshot","conversationId":4,"participants":["mo"],"messageId":2,"at":3,"snippet":""},
      {"kind":"hologram","at":1,"snippet":"x"}
     ]}
    """#)
    #expect(!answer.byModel)
    #expect(answer.filters.kinds == [.file, .other("hologram")])
    #expect(answer.filters.agent == nil && answer.filters.from == nil)
    #expect(answer.hits.map(\.kind) == [.file, .message, .screenshot, .other("hologram")])
    #expect(answer.hits[0].thread == nil && answer.hits[0].conversationId == nil)
    #expect(answer.hits[1].thread == .agent("ledger"))
    #expect(answer.hits[2].thread == .agent("mo"))
    #expect(answer.hits[3].agent == nil && answer.hits[3].thread == nil)
    #expect(Set(answer.hits.map(\.id)).count == 4)
}

@Test func aRewindPreviewDecodesWithKindsANewerDaemonAdds() throws {
    let preview: RewindPreview = try decode("""
        {"removed":4,"files":[{"agent":"ledger","takenAt":1700000000000,"added":["a.txt"],"changed":["b.txt","c.txt"],"removed":[]}],
         "noSnapshot":[],"cantUndo":[{"messageId":3,"kind":"mail","text":"ledger sent mail: mutt"},
         {"messageId":5,"kind":"teleport","text":"something new"}]}
        """)
    #expect(preview.removed == 4)
    #expect(preview.files[0].count == 3)
    #expect(preview.cantUndo.map(\.kind) == [.mail, .other("teleport")])
    #expect(preview.canPutFilesBack)
    let (lines, more) = preview.fileLines(limit: 2)
    #expect(lines == ["added    a.txt", "changed  b.txt"])
    #expect(more == 1)
    #expect(try encode(CantUndoKind.other("teleport")) == "\"teleport\"")
}

@Test func filesCannotGoBackWithoutASnapshotOrWithNothingChanged() throws {
    let missing: RewindPreview = try decode("""
        {"removed":1,"files":[{"agent":"a","takenAt":1,"added":["x"],"changed":[],"removed":[]}],"noSnapshot":["b"],"cantUndo":[]}
        """)
    #expect(!missing.canPutFilesBack)
    let unchanged: RewindPreview = try decode("""
        {"removed":1,"files":[{"agent":"a","takenAt":1,"added":[],"changed":[],"removed":[]}],"noSnapshot":[],"cantUndo":[]}
        """)
    #expect(!unchanged.canPutFilesBack)
}

@Test func aForwardSendsOnlyWhatWasPicked() throws {
    let file = ForwardFile(agent: "mo", path: "~/workspace/tap-receipt.pdf")
    #expect(try encode(Forwarding(messageId: 12, file: file).request(note: "  Book this as travel \n"))
        == #"{"file":{"agent":"mo","path":"~\/workspace\/tap-receipt.pdf"},"messageId":12,"note":"Book this as travel"}"#)
    #expect(try encode(Forwarding(messageId: 12).request(note: "   ")) == #"{"messageId":12}"#)
    #expect(Forwarding(file: file).fileName == "tap-receipt.pdf")

    let result: ForwardResult = try decode("""
        {"message":{"id":3,"role":"user","content":"x","createdAt":1},"file":{"path":"/home/agent-ledger/uploads/a.pdf","bytes":4}}
        """)
    #expect(result.file?.bytes == 4)
}

@Test func forwardingListsOtherAgentsWithAHomeOfTheirOwn() {
    let agents = [
        Agent(id: 1, name: "mo", display: 1, state: .idle, createdAt: 0),
        Agent(id: 2, name: "ledger", label: "Ledger", display: 2, state: .idle, createdAt: 0),
        Agent(id: 3, name: "mo-w1", display: 1001, state: .idle, parentId: 1, createdAt: 0),
    ]
    #expect(forwardTargets(agents, excluding: "mo").map(\.name) == ["ledger"])
    #expect(forwardTargets(agents, excluding: nil).map(\.name) == ["mo", "ledger"])
}

@Test func agentSuggestionDecodesWithAndWithoutAModel() throws {
    let full: AgentSuggestion = try decode(#"{"name":"scout","label":"Scout","tagline":"Support inbox","look":"cloud:teal","levels":{"browse":"on_its_own","send_messages":"ask_first"},"routine":{"cron":"0 8 * * 1-5","prompt":"Sweep new tickets."},"byModel":true}"#)
    #expect(full.look.flatMap(BloubIdentity.init(token:)) == BloubIdentity(shape: .cloud, color: .teal))
    #expect(full.levels["send_messages"] == .askFirst)
    #expect(full.routine == Routine(cron: "0 8 * * 1-5", prompt: "Sweep new tickets."))
    let plain: AgentSuggestion = try decode(#"{"name":"helper","label":"Helper","tagline":"Mind the books.","levels":{},"byModel":false}"#)
    #expect(plain.look == nil && plain.routine == nil && !plain.byModel)
}

@Test func newAgentPlanSendsTheDescriptionAndWhatCameWithIt() throws {
    var plan = NewAgentPlan()
    plan.label = " Scout "
    #expect(try encode(plan.request(name: "scout", look: "cloud:teal")) == #"{"label":"Scout","look":"cloud:teal","name":"scout"}"#)

    plan.description = " Watch the inbox. "
    plan.adopt(AgentSuggestion(
        name: "scout", label: "Scout", tagline: "Support inbox", look: nil,
        levels: ["send_messages": .askFirst, "passwords_security": .handToYou],
        routine: Routine(cron: " 0 8 * * 1-5 ", prompt: "Sweep."), byModel: true
    ))
    #expect(try encode(plan.request(name: "scout", look: "cloud:teal")) ==
        #"{"description":"Watch the inbox.","label":"Scout","levels":{"send_messages":"ask_first"},"look":"cloud:teal","name":"scout","routine":{"cron":"0 8 * * 1-5","prompt":"Sweep."},"tagline":"Support inbox"}"#)

    plan.tagline = " "
    plan.routine?.prompt = ""
    let bare = plan.request(name: "scout", look: "cloud:teal")
    #expect(bare.tagline == nil && bare.routine == nil)
}

@Test func rulesSummaryCountsRowsPerLevelLoosestFirst() {
    let levels: [String: RuleLevel] = [
        "browse": .onItsOwn, "run_commands": .onItsOwn, "write_files": .onItsOwn,
        "delete_files": .askFirst, "send_messages": .ifPreApproved, "spend_money": .askFirst,
        "install_software": .askFirst, "share_outside": .askFirst, "passwords_security": .handToYou,
    ]
    #expect(rulesSummary(levels) == "3 on its own · 1 if pre-approved · 4 ask first")
}

@Test func needsYouItemsGetTheDaemonsPushCategories() throws {
    func item(_ kind: String, approval: String? = nil) throws -> NeedsYouItem {
        let embedded = approval.map {
            #","approval":{"id":1,"agent":"a","conversationId":1,"#
                + $0 + #","target":"","participants":[],"reason":"r","createdAt":0}"#
        } ?? ""
        return try decode(
            #"{"id":"x","kind":""# + kind + #"","agent":"a","conversationId":1,"title":"t","createdAt":0,"actions":[]"#
                + embedded + "}"
        )
    }
    #expect(PushCategory.id(for: try item("approval", approval: #""kind":"action","category":"spend_money""#)) == "needs.approval")
    #expect(PushCategory.id(for: try item("approval", approval: #""kind":"action","category":"passwords_security""#)) == "needs.yours")
    #expect(PushCategory.id(for: try item("approval", approval: #""kind":"agent","category":"delete_files""#)) == "needs.delete")
    #expect(PushCategory.id(for: try item("hand_over")) == "needs.watch")
    #expect(PushCategory.id(for: try item("form")) == "needs.open")
    #expect(PushCategory.id(for: try item("mystery")) == "needs.open")
}

@Test func pushCategoryButtonsSendTheDaemonsActions() {
    let byId = Dictionary(uniqueKeysWithValues: PushCategory.all.map { ($0.identifier, $0.actions) })
    #expect(Set(byId.keys) == ["needs.approval", "needs.delete", "needs.yours", "needs.watch", "needs.open"])
    #expect(byId["needs.approval"]?.map(\.identifier) == ["approve", "deny"])
    #expect(byId["needs.delete"]?.map(\.title) == ["Keep it", "Delete it"])
    let delete = byId["needs.delete"]?.first { $0.identifier == "approve" }
    #expect(delete?.options.contains([.destructive, .authenticationRequired]) == true)
    #expect(byId["needs.approval"]?.first?.options.contains(.foreground) == false)
    #expect(byId["needs.watch"]?.first?.options.contains(.foreground) == true)
    #expect(PushCategory.answer("approve") == .approve)
    #expect(PushCategory.answer("deny") == .deny)
    #expect(PushCategory.answer("open") == nil)
    #expect(PushCategory.answer(UNNotificationDefaultActionIdentifier) == nil)
}
