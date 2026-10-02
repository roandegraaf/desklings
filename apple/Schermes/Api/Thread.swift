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

/// Every call on the page by its id, so the result rows that answer them are matched by lookup
/// rather than by a scan of the page per row.
func callIndex(_ loaded: [Message]) -> [String: ToolCall] {
    var calls: [String: ToolCall] = [:]
    for message in loaded {
        for call in message.toolCalls ?? [] where calls[call.id] == nil { calls[call.id] = call }
    }
    return calls
}

/// A page is a window on the rows, not on the turns, so a boundary can hand a reader a tool
/// result whose assistant message is on the page before it. It renders as itself with a note, and
/// the missing half arrives when the reader walks back one more page.
func isOrphanTool(_ message: Message, calls: [String: ToolCall]) -> Bool {
    guard message.role == .tool, let callId = message.toolCallId else { return false }
    return calls[callId] == nil
}

func isOrphanTool(_ message: Message, _ loaded: [Message]) -> Bool {
    isOrphanTool(message, calls: callIndex(loaded))
}

/// The call a tool result answers, when the assistant half of the turn is on the page. A result
/// row carries only the call's id, so an orphan has no call to find.
func toolCall(for message: Message, in loaded: [Message]) -> ToolCall? {
    message.toolCallId.flatMap { callIndex(loaded)[$0] }
}

func toolName(for message: Message, in loaded: [Message]) -> String? {
    toolCall(for: message, in: loaded)?.name
}

/// A screenshot the agent took to show the owner, with `show: true`, rather than only to look.
func isShown(_ message: Message, calls: [String: ToolCall]) -> Bool {
    guard message.image != nil, let callId = message.toolCallId, let call = calls[callId],
          let arguments = try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]
    else { return false }
    return arguments["show"] as? Bool == true
}

func isShown(_ message: Message, in loaded: [Message]) -> Bool {
    isShown(message, calls: callIndex(loaded))
}

/// `AGENT_NAME` in `daemon/src/agents.ts`: `^[a-z0-9][a-z0-9-]{0,30}$` in words rather than as a
/// regular expression, because that is the whole of it and a second dialect of regex is not.
func isAgentName(_ name: String) -> Bool {
    guard (1...MAX_AGENT_NAME).contains(name.count), let first = name.first, first != "-" else {
        return false
    }
    return name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
}

let MAX_AGENT_NAME = 31

/// `MAX_LABEL_CHARS` in `daemon/src/agents.ts`.
let MAX_AGENT_LABEL = 64

/// A label the daemon will keep: one line of it, and not an empty one. Counted in scalars rather
/// than characters, which is what the daemon counts, so an emoji is the same length on both sides.
func isAgentLabel(_ label: String) -> Bool {
    (1...MAX_AGENT_LABEL).contains(label.unicodeScalars.count) && !label.contains { $0.isNewline }
}

/// Shorter than `MAX_AGENT_NAME` on purpose: the daemon names a task worker `<parent>-w<n>`, and
/// a parent derived right up to the limit would have no room left for one.
let MAX_DERIVED_NAME = MAX_AGENT_NAME - 4

/// What a free-text name runs as: `Bob the Builder 🛠` becomes `bob-the-builder`. Other scripts
/// are transliterated rather than dropped, so a name written in one still yields a name a Linux
/// user can have; a name with nothing usable in it at all falls back to `agent`.
func slugged(_ label: String) -> String {
    let latin = label.applyingTransform(.toLatin, reverse: false) ?? label
    var slug = ""
    for character in latin.folding(options: .diacriticInsensitive, locale: nil).lowercased() {
        if character.isASCII && (character.isLetter || character.isNumber) {
            slug.append(character)
        } else if !slug.isEmpty && slug.last != "-" {
            slug.append("-")
        }
        if slug.count == MAX_DERIVED_NAME { break }
    }
    while slug.last == "-" { slug.removeLast() }
    return slug.isEmpty ? "agent" : slug
}

/// The name to create a free-text-named agent under: its slug, or the first free number after it
/// when something already holds that slug. Two agents the owner calls `Helper` are the owner's
/// business; two Linux users called `agent-helper` are not a thing that can exist.
func agentName(for label: String, taken: Set<String>) -> String {
    let stem = slugged(label)
    guard taken.contains(stem) else { return stem }
    let numbered = (2...1000).lazy.map { number -> String in
        let suffix = "-\(number)"
        var head = String(stem.prefix(MAX_DERIVED_NAME - suffix.count))
        while head.last == "-" { head.removeLast() }
        return head + suffix
    }
    return numbered.first { !taken.contains($0) } ?? stem
}

/// What to call the agents a row names by name: the participants of a thread and the sender of a
/// message are stored as names, and a reader wants the owner's word for them.
func titles(_ agents: [Agent]) -> [String: String] {
    Dictionary(agents.map { ($0.name, $0.title) }, uniquingKeysWith: { first, _ in first })
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

/// The workers still mid-task, which are the ones worth pinning in the parent's chat: finished
/// ones accumulate forever and stay folded away in the list.
func activeWorkers(of agent: Agent, in agents: [Agent]) -> [Agent] {
    agents.filter { $0.parentId == agent.id && $0.state.busy }
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

/// A stretch of tool traffic reads as one line, the way Claude Code folds it, narration included.
/// A screenshot the agent chose to show is drawn in the reply that follows it, where the reply
/// says what it is, rather than loose in the fold.
enum ChatItem: Identifiable {
    case message(Message, shown: [Base64Image] = [])
    case tools([ToolStep])
    /// A request for the owner's approval, out of the fold and drawn where it was asked.
    case request(ToolStep)

    var id: String {
        switch self {
        case .message(let message, _): "m\(message.id)"
        case .tools(let run): "t\(run[0].id)"
        case .request(let step): "r\(step.id)"
        }
    }

    var first: Message {
        switch self {
        case .message(let message, _): message
        case .tools(let run): run[0].message
        case .request(let step): step.message
        }
    }
}

let approvalTools: Set<String> = ["request_approval", "request_deletion"]

/// One row of a tool run, with the call it answers already looked up on the page.
struct ToolStep: Hashable, Identifiable {
    var message: Message
    var name: String?
    var orphaned: Bool
    var id: Int { message.id }
}

/// `breaks` starts a fresh item at a row something has to be drawn above: a day, the unread mark.
func chatItems(_ loaded: [Message], breaks: (Message) -> Bool = { _ in false }) -> [ChatItem] {
    let calls = callIndex(loaded)
    var items: [ChatItem] = []
    var run: [ToolStep] = []
    var shown: [Message] = []
    func fold() {
        if !run.isEmpty { items.append(.tools(run)) }
        run = []
    }
    for message in loaded {
        if isShown(message, calls: calls) { shown.append(message) }
        if message.hasBubble {
            fold()
            let own = message.role == .assistant ? shown.filter { $0.sender == message.sender } : []
            items.append(.message(message, shown: own.compactMap(\.image)))
            shown.removeAll { $0.sender == message.sender }
        } else {
            if breaks(message) { fold() }
            let step = ToolStep(
                message: message,
                name: message.toolCallId.flatMap { calls[$0]?.name },
                orphaned: isOrphanTool(message, calls: calls)
            )
            if message.role == .tool, let name = step.name, approvalTools.contains(name), !message.content.hasPrefix("error:") {
                fold()
                items.append(.request(step))
            } else {
                run.append(step)
            }
        }
    }
    fold()
    return items
}

/// The rows a day starts at, by id.
func dayStarts(_ loaded: [Message]) -> Set<Int> {
    let calendar = Calendar.current
    var starts: Set<Int> = []
    var previous: Date?
    for message in loaded {
        let day = Date(timeIntervalSince1970: Double(message.createdAt) / 1000)
        if previous.map({ !calendar.isDate($0, inSameDayAs: day) }) ?? true { starts.insert(message.id) }
        previous = day
    }
    return starts
}

/// What the chat draws, worked out once when the rows or the reader's mark change rather than on
/// every redraw: SwiftUI evaluates a body far more often than the rows change, and a thread of
/// hundreds of rows cannot afford a walk of the page per row each time.
struct ChatRows {
    var items: [ChatItem] = []
    var dayStarts: Set<Int> = []
    var unreadId: Int?
    /// By reply id: the row after the owner's message it answered, which is where a retry cuts.
    var retryFrom: [Int: Int] = [:]
    var interview: Interview?
    /// The tool row that said the browser stayed hung after its restart, while the owner hasn't answered it.
    var browserHang: Int?
    /// The agent's unanswered `ask_for_hands`, by the rule Needs you uses.
    var handOver: HandOver?
    /// The agent's unanswered `request_form`, by the same rule.
    var form: PendingForm?
    /// The agent's newest trigger proposal, until the owner writes after it fired.
    var trigger: PendingTrigger?
    /// The calls of the approval requests drawn in the thread.
    var requestCalls: [String] = []

    init() {}

    init(_ loaded: [Message], mark: Int) {
        let starts = Schermes.dayStarts(loaded)
        let unread = firstUnread(in: loaded, after: mark)
        dayStarts = starts
        unreadId = unread
        items = chatItems(loaded, breaks: { starts.contains($0.id) || $0.id == unread })
        var prompt: Int?
        for message in loaded {
            if message.role == .user {
                prompt = message.id
            } else if message.role == .assistant, let prompt {
                retryFrom[message.id] = prompt + 1
            }
        }
        interview = pendingInterview(in: loaded)
        browserHang = pendingBrowserHang(in: loaded)
        handOver = pendingHandOver(in: loaded)
        form = pendingForm(in: loaded)
        trigger = pendingTrigger(in: loaded)
        requestCalls = items.compactMap { item in
            if case .request(let step) = item { step.message.toolCallId } else { nil }
        }
    }
}

/// A `propose_trigger` the daemon stored, and how far its test has got in the transcript. The
/// trigger itself (state, URL, login) comes from the triggers listing.
struct PendingTrigger: Hashable {
    let callId: String
    let triggerId: Int
    /// The daemon's "Trigger N is on" line, the newest one.
    var turnedOn: Int?
    /// The first "Trigger N fired" row after that line.
    var firedAt: Int?
}

/// The newest trigger proposal. Once it fired after being turned on, the owner writing again ends the test.
func pendingTrigger(in loaded: [Message]) -> PendingTrigger? {
    guard let index = loaded.lastIndex(where: { $0.role == .assistant && $0.toolCalls?.contains { $0.name == "propose_trigger" } == true }),
          let call = loaded[index].toolCalls?.last(where: { $0.name == "propose_trigger" }),
          let result = loaded.first(where: { $0.role == .tool && $0.toolCallId == call.id }),
          let match = result.content.firstMatch(of: /^Proposed as trigger (\d+)\./),
          let id = Int(match.1)
    else { return nil }
    var pending = PendingTrigger(callId: call.id, triggerId: id)
    for message in loaded[index...] {
        if message.isTriggerLine, message.content.hasPrefix("Trigger \(id) is on:") {
            pending.turnedOn = message.id
            pending.firedAt = nil
        } else if pending.turnedOn != nil, pending.firedAt == nil, message.isTriggerLine,
                  message.content.hasPrefix("Trigger \(id) fired:") {
            pending.firedAt = message.createdAt
        } else if pending.firedAt != nil, message.isOwner {
            return nil
        }
    }
    return pending
}

struct HandOver: Hashable {
    let callId: String
    let reason: String
}

private struct AskForHandsArguments: Decodable {
    var reason: String
}

/// The newest `ask_for_hands` call, unless it was refused or the owner wrote after it (giving the
/// screen back writes that line).
func pendingHandOver(in loaded: [Message]) -> HandOver? {
    for message in loaded.reversed() {
        if message.isOwner { return nil }
        guard message.role == .assistant,
              let call = message.toolCalls?.first(where: { $0.name == "ask_for_hands" })
        else { continue }
        guard let result = loaded.first(where: { $0.role == .tool && $0.toolCallId == call.id }),
              !result.content.hasPrefix("error:"),
              let data = call.arguments.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(AskForHandsArguments.self, from: data)
        else { return nil }
        let reason = parsed.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? nil : HandOver(callId: call.id, reason: reason)
    }
    return nil
}

/// A `request_form` call still waiting. The fields aren't in the transcript: the Needs you item
/// whose `messageId` is `messageId` carries them.
struct PendingForm: Hashable {
    let callId: String
    let messageId: Int
}

/// The newest `request_form` call, unless it was refused or the owner wrote after it (the fill and
/// giving the screen back both write a line).
func pendingForm(in loaded: [Message]) -> PendingForm? {
    for message in loaded.reversed() {
        if message.isOwner { return nil }
        guard message.role == .assistant,
              let call = message.toolCalls?.first(where: { $0.name == "request_form" })
        else { continue }
        guard let result = loaded.first(where: { $0.role == .tool && $0.toolCallId == call.id }),
              !result.content.hasPrefix("error:")
        else { return nil }
        return PendingForm(callId: call.id, messageId: message.id)
    }
    return nil
}

/// How the daemon's browser tool starts its answer when a restart did not bring the browser back
/// (`BROWSER_HUNG` in `browser.ts`); Needs you finds the hang by the same words.
let browserHungPrefix = "error: your browser stopped answering"

/// The newest hung-browser tool row, unless the owner wrote after it (the restart routes write that line).
func pendingBrowserHang(in loaded: [Message]) -> Int? {
    for message in loaded.reversed() {
        if message.isOwner { return nil }
        if message.role == .tool, message.content.hasPrefix(browserHungPrefix) { return message.id }
    }
    return nil
}

struct InterviewOption: Decodable, Hashable {
    var label: String
    var description: String?
}

/// One question from an `ask_owner` call, as the daemon validated it: options to pick from, or
/// none for a free-text answer. Typing an answer of one's own is always allowed.
struct InterviewQuestion: Decodable, Hashable {
    var question: String
    var header: String?
    var options: [InterviewOption]?
    var multiple: Bool?
}

/// The questions an agent has put to the owner and is waiting on, with whatever it said as it
/// asked: that text rides in a reply with tool calls, which the thread folds, so the form is
/// where the owner reads it.
struct Interview: Hashable {
    let callId: String
    let intro: String
    let questions: [InterviewQuestion]
}

private struct AskOwnerArguments: Decodable {
    var questions: [InterviewQuestion]
}

/// The newest `ask_owner` the owner has not answered yet. The questions live in the call's own
/// arguments, so nothing is fetched: the thread is the queue. Anything of the owner's after the
/// call is the answer, and a call the daemon refused was never asked.
func pendingInterview(in loaded: [Message]) -> Interview? {
    for message in loaded.reversed() {
        if message.isOwner { return nil }
        guard message.role == .assistant,
              let call = message.toolCalls?.first(where: { $0.name == "ask_owner" })
        else { continue }
        let refused = loaded.contains { $0.role == .tool && $0.toolCallId == call.id && $0.content.hasPrefix("error:") }
        guard !refused,
              let data = call.arguments.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(AskOwnerArguments.self, from: data),
              !parsed.questions.isEmpty
        else { return nil }
        return Interview(callId: call.id, intro: message.content.trimmingCharacters(in: .whitespacesAndNewlines), questions: parsed.questions)
    }
    return nil
}

/// The owner's answers as one message, question by question, in words the agent reads back.
/// A header, when there is one, is a line of its own above the question, so reading the message
/// back never has to guess where a header ends and a question begins.
func interviewReply(_ questions: [InterviewQuestion], answers: [String]) -> String {
    zip(questions, answers).map { question, answer in
        let head = question.header.map { "\($0)\n" } ?? ""
        return "\(head)\(question.question)\n— \(answer.isEmpty ? "(skipped)" : answer)"
    }
    .joined(separator: "\n\n")
}

/// One answered question, as read back out of the message `interviewReply` wrote.
struct InterviewAnswer: Hashable {
    var header: String?
    var question: String
    /// Nil where the owner skipped the question.
    var answer: String?
}

/// The Q&A pairs in an owner message, if it is one `interviewReply` wrote: blocks of an optional
/// header line, a question line and a `— ` answer. Anything else is nil and drawn as the plain
/// text it is. The wire keeps the text, which is what the agent reads; this is only how the
/// owner sees it.
func interviewAnswers(_ content: String) -> [InterviewAnswer]? {
    var answers: [InterviewAnswer] = []
    for block in content.components(separatedBy: "\n\n") {
        guard let cut = block.range(of: "\n— ") else { return nil }
        let head = block[..<cut.lowerBound].components(separatedBy: "\n")
        let answer = String(block[cut.upperBound...])
        guard (1...2).contains(head.count), !head.contains(where: \.isEmpty), !answer.isEmpty else { return nil }
        answers.append(InterviewAnswer(
            header: head.count == 2 ? head[0] : nil,
            question: head[head.count - 1],
            answer: answer == "(skipped)" ? nil : answer
        ))
    }
    return answers.isEmpty ? nil : answers
}

/// The owner's word for whoever wrote a row, for a thread where that is worth saying.
func speaker(of message: Message, among members: [Agent]) -> String? {
    message.sender.map { titles(members)[$0] ?? $0 }
}

/// The name over a bubble. An agent's own rows in its own thread carry none. A `user` row with
/// a sender in a two-agent thread is one writing to the other, and reads nothing like that
/// agent's reply to the owner unless the label says so.
func speakerLabel(of message: Message, own: String?, among members: [Agent]) -> String? {
    guard let sender = message.sender, sender != own else { return nil }
    let name = titles(members)[sender] ?? sender
    if message.role == .user, members.count == 2, let other = members.first(where: { $0.name != sender }) {
        return "\(name) to \(other.title)"
    }
    return name
}

/// "Ran 2 shell commands, called browser 3 times". Results are not counted: each answers a call.
func toolSummary(_ run: [Message]) -> String {
    var order: [String] = []
    var counts: [String: Int] = [:]
    for call in run.flatMap({ $0.toolCalls ?? [] }) {
        let parts = call.name.components(separatedBy: "__")
        let key = parts.count >= 3 && parts[0] == "mcp" ? parts[1] : call.name
        if counts[key] == nil { order.append(key) }
        counts[key, default: 0] += 1
    }
    guard !order.isEmpty else {
        return run.count == 1 ? "1 tool result" : "\(run.count) tool results"
    }
    let phrases = order.map { key in
        let n = counts[key]!
        if key == "run_command" { return n == 1 ? "ran 1 shell command" : "ran \(n) shell commands" }
        return n == 1 ? "called \(key)" : "called \(key) \(n) times"
    }
    let line = phrases.joined(separator: ", ")
    return line.prefix(1).uppercased() + line.dropFirst()
}

/// A file an agent names in a reply: a path in its home, `~/…` or spelled out, with an extension.
/// The machine it is on is not the owner's, so a path alone is something they cannot open.
let filePath = #/(?:~|/home/[A-Za-z0-9._-]+)/[^\s`'"*<>()\[\]|]+\.[A-Za-z0-9]{1,8}/#
private let listItemPrefix = #/^[-*]\s+(.+)$/#

/// The file a line names when naming it is all the line does, bold, in code or as a list item.
/// Such a line is drawn as the file itself; a path inside a sentence stays part of the sentence.
func standaloneFile(_ line: some StringProtocol) -> String? {
    guard line.contains("/") else { return nil }
    var text = line.trimmingCharacters(in: .whitespaces)
    if let item = try? listItemPrefix.wholeMatch(in: text) { text = String(item.1) }
    text = text.trimmingCharacters(in: CharacterSet(charactersIn: "*_`"))
    return (try? filePath.wholeMatch(in: text)) == nil ? nil : text
}

/// The link a path inside a sentence becomes, and back.
func fileLink(_ path: String) -> URL? {
    var parts = URLComponents()
    parts.scheme = "schermes-file"
    parts.host = "open"
    parts.queryItems = [URLQueryItem(name: "path", value: path)]
    return parts.url
}

func linkedFile(_ url: URL) -> String? {
    guard url.scheme == "schermes-file" else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
}
