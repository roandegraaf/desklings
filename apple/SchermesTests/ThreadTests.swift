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

private func agent(_ id: Int, _ name: String, parentId: Int? = nil) -> Agent {
    Agent(
        id: id,
        name: name,
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

@Test func aReplyThatSaysSomethingAndCallsAToolShowsBoth() {
    let reply = message(1, role: .assistant, content: "Let me look.", toolCalls: [
        ToolCall(id: "shot-1", name: "computer", arguments: #"{"action":"screenshot"}"#)
    ])
    let result = message(2, role: .tool, content: "taken", toolCallId: "shot-1")
    #expect(reply.hasBubble && reply.hasToolLine)
    // Its tool line carries the call, not the words the bubble already shows.
    let line = ToolRow(message: reply, name: nil, orphaned: false)
    #expect(line.detail.contains("computer"))
    #expect(!line.detail.contains("Let me look."))
    // The result still finds the call it answers on that row.
    #expect(toolName(for: result, in: [reply, result]) == "computer")
    #expect(!isOrphanTool(result, [reply, result]))

    let callOnly = message(3, role: .assistant, content: "", toolCalls: [
        ToolCall(id: "cmd-1", name: "run_command", arguments: "{}")
    ])
    #expect(!callOnly.hasBubble && callOnly.hasToolLine)
    #expect(!result.hasBubble && result.hasToolLine)
    #expect(ToolRow(message: result, name: "computer", orphaned: false).detail.contains("taken"))
    #expect(message(4).hasBubble && !message(4).hasToolLine)
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
