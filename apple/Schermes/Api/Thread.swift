import Foundation

/// The daemon's own default page. Kept here so a short page can be recognised as the start of a
/// thread without the response having to say so.
let PAGE = 50

/// Everything a poll may bring back in one go, which is the daemon's maximum.
let CATCH_UP = 200

/// Pages arrive newest-first as the reader walks back and oldest-first as it catches up, and a
/// poll can repeat a row the reader already has. Keying by id and sorting covers all three, so
/// nothing anywhere else has to know which direction a page came from.
func merge(_ loaded: [Message], _ arriving: [Message]) -> [Message] {
    var byId = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
    for message in arriving { byId[message.id] = message }
    return byId.values.sorted { $0.id < $1.id }
}

/// What to ask for next. A poll walks on from the newest row the reader holds; a send walks on
/// from the cursor the reader held *before* it, because the daemon may have written rows in the
/// seconds since the last poll and the send's own row sits past them.
func catchUpWindow(after cursor: Int?) -> MessageWindow {
    cursor.map { MessageWindow(after: $0, limit: CATCH_UP) } ?? .newest
}

/// The proxy is a byte pipe with no RFB parser, so view-only is enforced by this client and
/// nothing else. Unknown ownership is therefore view-only: the safe answer is the one that cannot
/// put a pointer event on a desktop an agent is driving. The mirror of `viewOnly` in
/// `ui/src/thread.ts`.
nonisolated func viewOnly(_ held: Bool?) -> Bool {
    held != true
}

/// A page shorter than what was asked for is the start of the thread: there is nothing older.
func atStart(_ page: [Message], _ limit: Int) -> Bool {
    page.count < limit
}

func oldestId(_ loaded: [Message]) -> Int? {
    loaded.first?.id
}

func newestId(_ loaded: [Message]) -> Int? {
    loaded.last?.id
}

/// A page is a window on the rows, not on the turns, so a boundary can hand a reader a tool
/// result whose assistant message is on the page before it. It renders as itself with a note, and
/// the missing half arrives when the reader walks back one more page.
func isOrphanTool(_ message: Message, _ loaded: [Message]) -> Bool {
    guard message.role == .tool, let callId = message.toolCallId else { return false }
    return !loaded.contains { $0.toolCalls?.contains { $0.id == callId } == true }
}

/// What a tool result answers, when the assistant half of the turn is on the page. A result row
/// carries only the call's id, so an orphan has no name to show.
func toolName(for message: Message, in loaded: [Message]) -> String? {
    guard let callId = message.toolCallId else { return nil }
    return loaded.lazy.compactMap { $0.toolCalls?.first { $0.id == callId } }.first?.name
}

/// `AGENT_NAME` in `daemon/src/agents.ts`: `^[a-z0-9][a-z0-9-]{0,30}$` in words rather than as a
/// regular expression, because that is the whole of it and a second dialect of regex is not.
func isAgentName(_ name: String) -> Bool {
    guard (1...31).contains(name.count), let first = name.first, first != "-" else { return false }
    return name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
}

/// Task workers are agent rows that accumulate forever, so the list nests them under the agent
/// that spawned them rather than listing them beside it.
struct AgentTree: Identifiable, Hashable {
    var agent: Agent
    var workers: [Agent]

    /// The name rather than the row id. Agent ids and conversation ids are separate sequences of
    /// `Int`, so an agent and a thread can carry the same number, and a `List` that holds both
    /// kinds of row flattens them into one identity space where that number is all there is.
    var id: String { agent.name }
}

func groupAgents(_ agents: [Agent]) -> [AgentTree] {
    agents
        .filter { $0.parentId == nil }
        .map { agent in
            AgentTree(agent: agent, workers: agents.filter { $0.parentId == agent.id })
        }
}

/// The thread an agent shares with nobody but the owner is reached through the agent itself, so
/// the list shows only the ones it shares with somebody.
func sharedConversations(_ conversations: [Conversation], _ name: String) -> [Conversation] {
    conversations.filter { $0.participants.count > 1 || $0.participants.first != name }
}

extension AgentState {
    var label: String {
        switch self {
        case .idle: "idle"
        case .thinking: "thinking"
        case .using_computer: "using the computer"
        case .using_terminal: "using the terminal"
        case .waiting_for_user: "waiting for you"
        case .waiting_for_agent: "waiting for an agent"
        case .waiting_for_task_worker: "waiting for a task worker"
        case .failed: "failed"
        case .completed: "completed"
        }
    }

    /// Mid-turn, which is what tells a reader the thread is still moving.
    var busy: Bool {
        self == .thinking || self == .using_computer || self == .using_terminal
    }
}
