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

/// The call a tool result answers, when the assistant half of the turn is on the page. A result
/// row carries only the call's id, so an orphan has no call to find.
func toolCall(for message: Message, in loaded: [Message]) -> ToolCall? {
    guard let callId = message.toolCallId else { return nil }
    return loaded.lazy.compactMap { $0.toolCalls?.first { $0.id == callId } }.first
}

func toolName(for message: Message, in loaded: [Message]) -> String? {
    toolCall(for: message, in: loaded)?.name
}

/// A screenshot the agent took to show the owner, with `show: true`, rather than only to look.
func isShown(_ message: Message, in loaded: [Message]) -> Bool {
    guard message.image != nil, let call = toolCall(for: message, in: loaded),
          let arguments = try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]
    else { return false }
    return arguments["show"] as? Bool == true
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
    case tools([Message])

    var id: String {
        switch self {
        case .message(let message, _): "m\(message.id)"
        case .tools(let run): "t\(run[0].id)"
        }
    }

    var first: Message {
        switch self {
        case .message(let message, _): message
        case .tools(let run): run[0]
        }
    }
}

/// `breaks` starts a fresh item at a row something has to be drawn above: a day, the unread mark.
func chatItems(_ loaded: [Message], breaks: (Message) -> Bool = { _ in false }) -> [ChatItem] {
    var items: [ChatItem] = []
    var shown: [Message] = []
    for message in loaded {
        if isShown(message, in: loaded) { shown.append(message) }
        if message.hasBubble {
            let own = message.role == .assistant ? shown.filter { $0.sender == message.sender } : []
            items.append(.message(message, shown: own.compactMap(\.image)))
            shown.removeAll { $0.sender == message.sender }
        } else if !breaks(message), case .tools(let run) = items.last {
            items[items.count - 1] = .tools(run + [message])
        } else {
            items.append(.tools([message]))
        }
    }
    return items
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
