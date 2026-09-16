import Foundation
import Testing
@testable import Schermes

/// The same cases as `ui/src/thread.test.ts`, against the Swift mirror of those helpers.

private func message(_ id: Int, role: MessageRole = .user, content: String? = nil,
                     toolCallId: String? = nil, toolCalls: [ToolCall]? = nil) -> Message {
    Message(
        id: id,
        role: role,
        content: content ?? "m\(id)",
        toolCalls: toolCalls,
        toolCallId: toolCallId,
        createdAt: id
    )
}

private let askCall = ToolCall(
    id: "q1",
    name: "ask_owner",
    arguments: #"{"questions":[{"question":"What am I for?","header":"Purpose","options":[{"label":"Sheets"},{"label":"Email","description":"triage it"}],"multiple":true},{"question":"Anything else?"}]}"#
)

@Test func theNewestUnansweredQuestionIsPendingUntilTheOwnerWrites() {
    let asked = [
        message(1),
        message(2, role: .assistant, content: "Hi, I am Excel. \n", toolCalls: [askCall]),
        message(3, role: .tool, content: "Asked the owner 2 questions.", toolCallId: "q1"),
    ]
    let pending = pendingInterview(in: asked)
    #expect(pending?.callId == "q1")
    #expect(pending?.intro == "Hi, I am Excel.")
    #expect(pending?.questions.map(\.question) == ["What am I for?", "Anything else?"])
    #expect(pending?.questions[0].options?.map(\.label) == ["Sheets", "Email"])
    #expect(pending?.questions[0].multiple == true)
    #expect(pending?.questions[1].options == nil)

    // Answered: nothing to show. A later question of the agent's is pending again.
    #expect(pendingInterview(in: asked + [message(4)]) == nil)
    let again = asked + [message(4), message(5, role: .assistant, content: "", toolCalls: [ToolCall(id: "q2", name: "ask_owner", arguments: askCall.arguments)])]
    #expect(pendingInterview(in: again)?.callId == "q2")

    // A call the daemon refused was never asked, and a call nothing asked is not one either.
    let refused = [
        message(1),
        message(2, role: .assistant, content: "", toolCalls: [askCall]),
        message(3, role: .tool, content: "error: questions must be a list", toolCallId: "q1"),
    ]
    #expect(pendingInterview(in: refused) == nil)
    #expect(pendingInterview(in: [message(1), message(2, role: .assistant, toolCalls: [ToolCall(id: "c", name: "run_command", arguments: "{}")])]) == nil)
}

@Test func answersReadBackQuestionByQuestion() {
    let questions = pendingInterview(in: [message(2, role: .assistant, content: "", toolCalls: [askCall])])!.questions
    let reply = interviewReply(questions, answers: ["Sheets; Email", ""])
    #expect(reply == """
    Purpose
    What am I for?
    — Sheets; Email

    Anything else?
    — (skipped)
    """)
    // And parses back into what the card is drawn from, header and skip included.
    #expect(interviewAnswers(reply) == [
        InterviewAnswer(header: "Purpose", question: "What am I for?", answer: "Sheets; Email"),
        InterviewAnswer(header: nil, question: "Anything else?", answer: nil),
    ])
    // A typed answer keeps its own line breaks.
    #expect(interviewAnswers("Anything else?\n— Two things.\nNo, three.")?.first?.answer == "Two things.\nNo, three.")
    // Anything that is not the reply shape is plain text.
    #expect(interviewAnswers("You will be the CEO of my company") == nil)
    #expect(interviewAnswers("Purpose\nwhat?\n— yes\n\nloose text") == nil)
    #expect(interviewAnswers("a\nb\nc\n— too many head lines") == nil)
}

@Test func mergeKeepsOneRowPerIdAndOrdersOldestFirst() {
    let merged = merge([message(3), message(4)], [message(1), message(2)])
    #expect(merged.map(\.id) == [1, 2, 3, 4])
}

@Test func mergeReplacesARowAPollReturnedAgainRatherThanDuplicatingIt() {
    let loaded = [message(1), message(2, content: "stale")]
    let merged = merge(loaded, [message(2, content: "fresh")])
    #expect(merged.map(\.id) == [1, 2])
    #expect(merged[1].content == "fresh")
}

@Test func aShortPageIsTheStartOfTheThreadAndAFullOneIsNot() {
    #expect(atStart([message(1), message(2)], 50))
    #expect(!atStart([message(1), message(2)], 2))
    #expect(atStart([], 50))
}

@Test func theEndsOfALoadedThreadAreWhatTheReaderPagesFrom() {
    #expect(oldestId([]) == nil)
    #expect(newestId([]) == nil)
    #expect(oldestId([message(7), message(9)]) == 7)
    #expect(newestId([message(7), message(9)]) == 9)
}

@Test func aToolRowWhoseAssistantMessageIsOnAnEarlierPageIsAnOrphan() {
    let orphan = message(2, role: .tool, content: "ok", toolCallId: "call-1")
    #expect(isOrphanTool(orphan, [orphan]))

    let asked = message(1, role: .assistant, content: "", toolCalls: [
        ToolCall(id: "call-1", name: "screenshot", arguments: "{}")
    ])
    #expect(!isOrphanTool(orphan, [asked, orphan]))
}

@Test func onlyToolRowsCanBeOrphans() {
    #expect(!isOrphanTool(message(1), [message(1)]))
}

@Test func aToolResultIsNamedByTheCallItAnswers() {
    let asked = message(1, role: .assistant, content: "", toolCalls: [
        ToolCall(id: "shot-1", name: "computer", arguments: #"{"action":"screenshot"}"#)
    ])
    let result = message(2, role: .tool, content: "taken", toolCallId: "shot-1")
    #expect(toolName(for: result, in: [asked, result]) == "computer")
    #expect(toolName(for: result, in: [result]) == nil)
    #expect(toolName(for: message(3), in: [message(3)]) == nil)
}

@Test func busyIsTheThreeMidTurnStates() {
    #expect(AgentState.allCases.filter(\.busy) == [.thinking, .using_computer, .using_terminal])
}

@Test func everyStateHasALabel() {
    #expect(AgentState.allCases.allSatisfy { !$0.label.isEmpty })
    #expect(AgentState.waiting_for_task_worker.label == "waiting for a task worker")
}

private func agent(_ id: Int, _ name: String, label: String? = nil, parentId: Int? = nil) -> Agent {
    Agent(
        id: id,
        name: name,
        label: label,
        display: parentId == nil ? id : 1000 + id,
        state: .idle,
        parentId: parentId,
        createdAt: id
    )
}

@Test func taskWorkersAreNestedUnderTheAgentThatSpawnedThem() {
    let trees = groupAgents([
        agent(1, "one"),
        agent(2, "two"),
        agent(3, "one-w1", parentId: 1),
        agent(4, "one-w2", parentId: 1),
    ])
    #expect(trees.map(\.agent.name) == ["one", "two"])
    #expect(trees[0].workers.map(\.name) == ["one-w1", "one-w2"])
    #expect(trees[1].workers.isEmpty)
}

@Test func anAgentsOwnThreadIsNotListedBesideTheOnesItShares() {
    let conversations = [
        Conversation(id: 1, participants: ["one"], createdAt: 1),
        Conversation(id: 2, participants: ["one", "two"], createdAt: 2),
    ]
    #expect(sharedConversations(conversations, "one").map(\.id) == [2])
}

@Test func aThreadSourceNamesItselfTheSameWayTwice() {
    #expect(ThreadSource.agent("one").key == "agent:one")
    #expect(ThreadSource.conversation(4).key == "conversation:4")
    #expect(ThreadSource.agent("4") != ThreadSource.conversation(4))
}

@Test func aThreadNobodyHasOpenedIsEntirelyUnread() {
    let suite = "dev.schermes.tests.unread"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    let store = UserDefaults(suiteName: suite)!
    let unread = Unread(defaults: store)
    let thread = ThreadSource.agent("one")

    #expect(unread.lastSeen(thread) == 0)
    #expect(unread.has(thread, newest: 1))
    // Nothing has arrived, so there is nothing to have missed.
    #expect(!unread.has(thread, newest: nil))

    unread.see(thread, through: 7)
    #expect(!unread.has(thread, newest: 7))
    #expect(unread.has(thread, newest: 8))

    // A page walked back must not drag the mark backwards with it.
    unread.see(thread, through: 2)
    #expect(unread.lastSeen(thread) == 7)

    // Kept per thread, and read back after a relaunch.
    #expect(!unread.has(.conversation(1), newest: nil))
    #expect(Unread(defaults: store).lastSeen(thread) == 7)
}

@Test func aBareHostIsGivenAScheme() {
    #expect(Session.parse("127.0.0.1:7777")?.absoluteString == "http://127.0.0.1:7777")
    #expect(Session.parse(" https://box.local ")?.absoluteString == "https://box.local")
    #expect(Session.parse("schermes.example.com")?.absoluteString == "https://schermes.example.com")
    #expect(Session.parse("schermes.example.com/")?.absoluteString == "https://schermes.example.com/")
    #expect(Session.parse("nas.local:7777")?.absoluteString == "http://nas.local:7777")
    #expect(Session.parse("nas:7777")?.absoluteString == "http://nas:7777")
    #expect(Session.parse("192.168.1.20:7777")?.absoluteString == "http://192.168.1.20:7777")
    #expect(Session.parse("") == nil)
    #expect(Session.parse("   ") == nil)
}

@Test func aStoredPasswordIsOnlyLookedUpForTheDaemonItWasSetOn() async {
    let old = Session.parse("127.0.0.1:7777")!
    let new = Session.parse("192.168.1.20:7777")!
    var asked: [URL] = []
    let back = await Session.reLogin(SchermesClient(baseURL: new)) { daemon in
        asked.append(daemon)
        return daemon == old ? "the old daemon's password" : nil
    }
    #expect(!back)
    #expect(asked == [new])

    // One Keychain item per daemon address, however the address was typed.
    let account = { (url: URL) in Keychain.query(for: url)[kSecAttrAccount as String] as? String }
    #expect(account(old) != account(new))
    #expect(account(old) != account(Session.parse("https://127.0.0.1:7777")!))
    #expect(account(old) == account(Session.parse("http://127.0.0.1:7777")!))
    #expect(account(old) != "password")
}

@Test func aRoutineFiringIsNewAndLeavesTheDividerWhereItWas() {
    let agentSays = { (id: Int) in message(id, role: .assistant) }
    // The daemon delivers a routine as a `user` row with no sender: the owner's shape.
    let routineFires = { (id: Int) in message(id, content: "Scheduled task 1 (0 9 * * *) is due.") }
    #expect(firstUnread(in: [agentSays(1), routineFires(2)], after: 1) == 2)
    #expect(firstUnread(in: [agentSays(1), agentSays(2), routineFires(3)], after: 1) == 2)
    #expect(firstUnread(in: [agentSays(1), agentSays(2), routineFires(3), agentSays(4), routineFires(5)],
                        after: 1) == 2)
}

@Test func nothingAboveTheOwnersSendIsNew() {
    let agentSays = { (id: Int) in message(id, role: .assistant) }
    let ownerSends = { (id: Int) in message(id) }
    let routineFires = { (id: Int) in message(id, content: "Scheduled task 1 (0 9 * * *) is due.") }
    // Sending moves the mark to the sent row.
    #expect(firstUnread(in: [agentSays(1), agentSays(2), ownerSends(3)], after: 3) == nil)
    #expect(firstUnread(in: [agentSays(1), ownerSends(2), agentSays(3)], after: 2) == 3)
    #expect(firstUnread(in: [agentSays(1), ownerSends(2), routineFires(3), agentSays(4)], after: 2) == 3)
}

@Test func wordsSaidAlongsideCallsFoldInWithThem() {
    let reply = message(1, role: .assistant, content: "Let me look.", toolCalls: [
        ToolCall(id: "shot-1", name: "computer", arguments: #"{"action":"screenshot"}"#)
    ])
    let result = message(2, role: .tool, content: "taken", toolCallId: "shot-1")
    #expect(!reply.hasBubble)
    // Its tool line carries the call; the run draws the words above it.
    let line = ToolRow(message: reply, name: nil, orphaned: false)
    #expect(line.detail.contains("computer"))
    #expect(!line.detail.contains("Let me look."))
    // The result still finds the call it answers on that row.
    #expect(toolName(for: result, in: [reply, result]) == "computer")
    #expect(!isOrphanTool(result, [reply, result]))

    let callOnly = message(3, role: .assistant, content: "", toolCalls: [
        ToolCall(id: "cmd-1", name: "run_command", arguments: "{}")
    ])
    #expect(!callOnly.hasBubble)
    #expect(!result.hasBubble)
    #expect(ToolRow(message: result, name: "computer", orphaned: false).detail.contains("taken"))
    #expect(message(4).hasBubble)
    #expect(message(5, role: .assistant, content: "Done.").hasBubble)
}

@Test func aSendCatchesUpFromTheCursorItHeldBeforeIt() {
    // The reader holds 1 and 2; the agent wrote 3 and 4 in the seconds since the last poll, and
    // the send created 5.
    let loaded = [message(1), message(2)]
    let cursor = newestId(loaded)
    let sent = message(5)

    // Merging only the sent row moves the poll's cursor past 3 and 4, which then never arrive.
    #expect(merge(loaded, [sent]).map(\.id) == [1, 2, 5])

    // Asking from the cursor held before the send brings them with it.
    #expect(catchUpWindow(after: cursor).after == 2)
    #expect(catchUpWindow(after: cursor).limit == CATCH_UP)
    let page = [message(3, role: .assistant), message(4, role: .tool, toolCallId: "c1"), sent]
    #expect(merge(merge(loaded, [sent]), page).map(\.id) == [1, 2, 3, 4, 5])

    // An empty thread has no cursor, so the send asks for the newest page instead — and the
    // cursor being nil must not be read as "no cursor given" and replaced with the sent row's id,
    // which would skip everything written before it.
    let firstEver = message(1)
    let opening = newestId([])
    #expect(opening == nil)
    #expect(catchUpWindow(after: opening).after == nil)
    #expect(catchUpWindow(after: opening).limit == nil)
    #expect(catchUpWindow(after: newestId(merge([], [firstEver]))).after == 1)
}

@Test func anAgentNameIsTheDaemonsOwnRule() {
    for name in ["alpha", "a", "agent-1", "0", String(repeating: "a", count: 31)] {
        #expect(isAgentName(name), "\(name) should be accepted")
    }
    for name in ["", "-leading", "Alpha", "has space", "semi;rm -rf /", "../escape", "aé",
                 String(repeating: "a", count: 32)] {
        #expect(!isAgentName(name), "\(name) should be refused")
    }
}

@Test func aReaderIsShownTheOwnersNameAndAWorkerFallsBackToItsOwn() {
    #expect(agent(1, "bob-the-builder", label: "Bob the Builder").title == "Bob the Builder")
    #expect(agent(2, "alpha").title == "alpha")
    #expect(titles([agent(1, "alpha", label: "Bob"), agent(2, "beta")]) == ["alpha": "Bob", "beta": "beta"])
}

@Test func aFreeTextNameIsSluggedIntoSomethingALinuxUserCanBe() {
    #expect(slugged("Bob the Builder") == "bob-the-builder")
    #expect(slugged("  Ünïcôdé  Ågent!! ") == "unicode-agent")
    #expect(slugged("--Bob--") == "bob")
    #expect(slugged("🎉🎉") == "agent", "nothing usable in it still yields a name")
    let long = slugged(String(repeating: "ab ", count: 20))
    #expect(long.count <= MAX_DERIVED_NAME, "room is left for a -w<n> worker name")
    #expect(isAgentName("\(long)-w99"), "a worker of it still fits the daemon's rule")
    #expect(!long.hasSuffix("-"), "no trailing dash after the cut")
    for label in ["Bob the Builder", "🎉🎉", "Ünïcôdé", String(repeating: "ab ", count: 20), "北京"] {
        #expect(isAgentName(slugged(label)), "\(label) slugged to \(slugged(label))")
    }
}

@Test func aSlugSomethingElseAlreadyHoldsTakesTheNextNumber() {
    #expect(agentName(for: "Bob", taken: []) == "bob")
    #expect(agentName(for: "Bob", taken: ["bob"]) == "bob-2")
    #expect(agentName(for: "Bob", taken: ["bob", "bob-2"]) == "bob-3")
    let wordy = String(repeating: "a", count: 40)
    let numbered = agentName(for: wordy, taken: [String(repeating: "a", count: MAX_DERIVED_NAME)])
    #expect(isAgentName(numbered))
    #expect(isAgentName("\(numbered)-w9"))
}

@Test func aLabelIsOneLineOfAReadableLength() {
    #expect(isAgentLabel("Bob"))
    #expect(isAgentLabel(String(repeating: "a", count: 64)))
    #expect(!isAgentLabel(""))
    #expect(!isAgentLabel(String(repeating: "a", count: 65)))
    #expect(!isAgentLabel("two\nlines"))
}

@Test func toolTrafficFoldsIntoOneLinePerStretch() {
    let say = message(1, role: .assistant, content: "Looking.", toolCalls: [
        ToolCall(id: "a", name: "run_command", arguments: "{}")
    ])
    let result = message(2, role: .tool, content: "ok", toolCallId: "a")
    let calls = message(3, role: .assistant, content: "", toolCalls: [
        ToolCall(id: "b", name: "mcp__chrome-devtools__click", arguments: "{}"),
        ToolCall(id: "c", name: "mcp__chrome-devtools__navigate_page", arguments: "{}"),
    ])
    let results = [message(4, role: .tool, toolCallId: "b"), message(5, role: .tool, toolCallId: "c")]
    let rows = [say, result, calls] + results + [message(6, role: .assistant, content: "Done.")]

    let items = chatItems(rows)
    #expect(items.map(\.id) == ["t1", "m6"])
    guard case .tools(let run) = items[0] else { Issue.record("no run"); return }
    #expect(run.map(\.id) == [1, 2, 3, 4, 5])
    #expect(toolSummary(run) == "Ran 1 shell command, called chrome-devtools 2 times")

    #expect(chatItems(rows, breaks: { $0.id == 4 }).map(\.id) == ["t1", "t4", "m6"])
    #expect(toolSummary([message(9, role: .tool, toolCallId: "gone")]) == "1 tool result")
}

@Test func onlyAScreenshotTheAgentChoseToShowLandsInItsReply() {
    let shot = Base64Image(mediaType: "image/png", base64: "")
    let calls = message(1, role: .assistant, content: "", toolCalls: [
        ToolCall(id: "look", name: "computer", arguments: #"{"action":"screenshot"}"#),
        ToolCall(id: "show", name: "computer", arguments: #"{"action":"screenshot","show":true}"#),
    ])
    var looked = message(2, role: .tool, toolCallId: "look")
    looked.image = shot
    var shown = message(3, role: .tool, toolCallId: "show")
    shown.image = shot
    let rows = [calls, looked, shown]
    #expect(!isShown(looked, in: rows))
    #expect(isShown(shown, in: rows))
    #expect(!isShown(shown, in: [shown]), "an orphan's call is not on the page to say so")

    var reply = message(4, role: .assistant, content: "Here is the screen.")
    reply.sender = "alpha"
    var ownRows = rows.map { row -> Message in var row = row; row.sender = "alpha"; return row }
    ownRows.append(reply)
    let items = chatItems(ownRows + [message(5)])
    #expect(items.map(\.id) == ["t1", "m4", "m5"])
    guard case .message(_, let attached) = items[1], case .message(_, let none) = items[2] else {
        Issue.record("no replies"); return
    }
    #expect(attached == [shot], "only the shown one, once")
    #expect(none.isEmpty, "the owner's next message carries nothing")
}
