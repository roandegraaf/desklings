import Foundation

/// One-to-one mirrors of `shared/src/index.ts`: same names, same field names, same optionality.
/// When `shared` changes, this file changes in the same commit.

public let MIN_PASSWORD_LENGTH = 8

struct HealthResponse: Codable, Sendable {
    var status: String
    var setupRequired: Bool
}

/// An endpoint and its key, shared by every model on it. The key is only ever reported as set or not.
struct ProviderEntry: Codable, Sendable, Identifiable, Equatable {
    var id: Int
    var name: String
    var baseUrl: String
    var apiKeySet: Bool
    var createdAt: Int
}

/// `POST /api/providers` needs name and baseUrl; `PUT /api/providers/:id` keeps what is left out.
/// An empty `apiKey` removes the stored key, so a blank key field is sent as nothing.
struct ProviderUpdate: Encodable, Sendable, Equatable {
    var name: String? = nil
    var baseUrl: String? = nil
    var apiKey: String? = nil
}

/// One entry of the model registry. `baseUrl` and `apiKeySet` are its provider's. The provider
/// fields are optional so a daemon from before providers still decodes.
struct ModelEntry: Codable, Sendable, Identifiable, Equatable {
    var id: Int
    var name: String
    var providerId: Int?
    var providerName: String?
    var baseUrl: String
    var model: String
    var apiKeySet: Bool
    var extraBody: String
    /// In tokens, or nil when unknown. Absent on a daemon from before model capabilities.
    var contextWindow: Int? = nil
    /// Absent on a daemon from before model capabilities, which sent images to every model.
    var vision: Bool? = nil
    var isDefault: Bool
    var isBackup: Bool
    var createdAt: Int

    var seesImages: Bool { vision ?? true }
}

/// `POST /api/models` needs name, providerId and model; `PUT /api/models/:id` keeps what is left out.
/// `contextWindow` is doubly optional: `nil` leaves it out, `.some(nil)` sends `null`, which clears it.
struct ModelUpdate: Encodable, Sendable, Equatable {
    var name: String? = nil
    var providerId: Int? = nil
    var model: String? = nil
    var extraBody: String? = nil
    var contextWindow: Int?? = nil
    var vision: Bool? = nil

    private enum Keys: String, CodingKey { case name, providerId, model, extraBody, contextWindow, vision }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(providerId, forKey: .providerId)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(extraBody, forKey: .extraBody)
        if let contextWindow {
            if let contextWindow { try container.encode(contextWindow, forKey: .contextWindow) }
            else { try container.encodeNil(forKey: .contextWindow) }
        }
        try container.encodeIfPresent(vision, forKey: .vision)
    }
}

/// The owner's clock and how long agent screenshots are kept. Both are absent on an older daemon.
struct GeneralSettings: Sendable, Equatable {
    var timezone: String?
    var imageRetentionDays: Int?
}

struct GeneralSettingsUpdate: Codable, Sendable {
    var timezone: String? = nil
    var imageRetentionDays: Int? = nil
}

/// One signed-in client. `handle` names it for a revoke; the session id itself is the cookie and
/// is never sent.
struct SessionEntry: Codable, Sendable, Identifiable, Equatable {
    var handle: String
    var createdAt: Int
    var lastSeenAt: Int?
    var userAgent: String?
    var current: Bool

    var id: String { handle }
}

struct PasswordChanged: Codable, Sendable {
    /// How many other sessions the change signed out.
    var signedOut: Int
}

struct TotpStatus: Codable, Sendable, Equatable {
    var enabled: Bool
    var pending: Bool
    var recoveryCodesLeft: Int
}

struct TotpSetup: Codable, Sendable, Equatable {
    /// Base32, for typing into an authenticator by hand.
    var secret: String
    var uri: String
}

struct TotpConfirmed: Codable, Sendable {
    /// Shown once: the daemon keeps only their hashes.
    var recoveryCodes: [String]
}

enum AuditAction: String, Codable, Sendable, TolerantEnum {
    case setup
    case login
    case login_failed
    case logout
    case password_changed
    case password_change_failed
    case session_revoked
    case totp_enabled
    case totp_disabled
    case recovery_code_used
    case settings_changed
    case provider_changed
    case model_changed
    case mcp_changed
    case rules_changed
    case unknown
}

struct AuditEvent: Codable, Sendable, Identifiable, Equatable {
    var id: Int
    var at: Int
    var action: AuditAction
    var ip: String?
    var userAgent: String?
    var detail: [String: JSONValue]?
}

struct WebSettings: Codable, Sendable {
    var searchUrl: String
    var searchKeySet: Bool
}

struct WebSettingsUpdate: Codable, Sendable {
    var searchUrl: String? = nil
    var searchKey: String? = nil
}

/// The APNs half of the settings. The `.p8` key is reported as present or absent like the other
/// keys; `sandbox` picks Apple's development gateway, which is where a development build lands.
struct PushSettings: Codable, Sendable {
    var keyId: String
    var teamId: String
    var bundleId: String
    var keySet: Bool
    var sandbox: Bool
}

struct PushSettingsUpdate: Codable, Sendable {
    var pushKeyId: String? = nil
    var pushKey: String? = nil
}

/// A device the daemon can push to. The token is APNs' hex, one row per device.
struct Device: Codable, Sendable, Identifiable, Hashable {
    var token: String
    var platform: String
    var createdAt: Int

    var id: String { token }
}

struct PushTestResult: Codable, Sendable {
    var ok: Bool
    var sent: Int
    var error: String?
}

struct McpServerSummary: Codable, Sendable {
    enum Transport: String, Codable, Sendable, TolerantEnum { case stdio, http, unknown }
    var name: String
    var transport: Transport
    var command: String?
    var args: [String]?
    var url: String?
    var secretKeys: [String]
}

struct McpTestResult: Codable, Sendable {
    var ok: Bool
    var tools: [String]
    var error: String?
}

/// The envelope every daemon failure arrives in. `SchermesError` is what the client throws once
/// it has read one.
struct ApiError: Codable, Sendable {
    var error: String
    /// On a login's 401: the password was right and a code has to go with it.
    var totpRequired: Bool?
}

/// A raw-value enum the daemon sends, decoded so that a value a newer daemon adds becomes
/// `unknown` instead of failing the whole page it arrived in.
nonisolated protocol TolerantEnum: RawRepresentable, Decodable where RawValue == String {
    static var unknown: Self { get }
}

nonisolated extension TolerantEnum {
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

enum AgentState: String, Codable, CaseIterable, Sendable, TolerantEnum {
    case idle
    case thinking
    case using_computer
    case using_terminal
    case waiting_for_user
    case waiting_for_agent
    case waiting_for_task_worker
    case failed
    case completed
    case unknown
}

struct LiveReply: Codable, Sendable, Equatable {
    var text: String
    var reasoning: String
    var retry: RetryState? = nil

    var isEmpty: Bool { text.isEmpty && reasoning.isEmpty && retry == nil }
}

/// A model call waiting to be asked again after a rate limit or a server error.
struct RetryState: Codable, Sendable, Equatable {
    /// The attempt that comes next, counting the first call as 1.
    var attempt: Int
    var of: Int
    /// Epoch milliseconds.
    var retryAt: Int
    var error: String
    var model: String
    /// The backup's name while this turn can still switch to it.
    var backup: String?
}

struct Agent: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    /// What the owner calls it, free text and cosmetic. `name` is still what runs as a Linux
    /// user, what the agents address each other by and what every route is keyed on; changing
    /// it moves all three, which `updateAgent(slug:)` asks the daemon to do.
    var label: String?
    /// How a client draws it, an opaque token the daemon stores and every device reads, so the
    /// avatar picked on one is the avatar on all of them. `BloubIdentity` owns the format.
    var look: String?
    /// Who it is, in Markdown, written by the agent after interviewing the owner or by the owner
    /// on the Profile page. Absent until then, and on a task worker.
    var profile: String?
    var display: Int
    var state: AgentState
    var parentId: Int?
    var parentConversationId: Int?
    var createdAt: Int
    /// How full its own thread is, 0–100. Only the polled list carries it.
    var contextFullness: Int?
    /// The registry entry it runs on. Absent means the default; a worker runs on its parent's.
    var modelId: Int?

    /// What to show a reader. Never what to send: a route, a look and a thread key take `name`.
    var title: String { label ?? name }

    /// The one line beside the name: the profile's first line of prose.
    var tagline: String? {
        profile?.split(whereSeparator: \.isNewline)
            .first { !$0.hasPrefix("#") && !$0.allSatisfy(\.isWhitespace) }
            .map { plainPreview(String($0)) }
    }
}

enum ComputerActionName: String, Codable, CaseIterable, Sendable {
    case screenshot
    case move
    case click
    case drag
    case scroll
    case type
    case key
    case clipboard_read
    case clipboard_write
}

enum ScrollDirection: String, Codable, Sendable {
    case up, down, left, right
}

/// Flat rather than a Swift enum with associated values: the daemon reads these as flat fields off
/// one JSON object, and `encodeIfPresent` leaves out whatever an action does not carry.
struct ComputerAction: Codable, Sendable {
    var action: ComputerActionName
    var x: Int? = nil
    var y: Int? = nil
    var toX: Int? = nil
    var toY: Int? = nil
    var button: Int? = nil
    var direction: ScrollDirection? = nil
    var amount: Int? = nil
    var text: String? = nil
    var keys: String? = nil
}

/// A screenshot travels as base64 in JSON; see docs/architecture.md for why.
struct Base64Image: Codable, Sendable, Hashable {
    var mediaType: String
    var base64: String
    /// The daemon pruned the bytes past its retention window; `base64` is then empty.
    var expired: Bool? = nil
}

/// What `POST .../compact` did: how many rows each agent's new summary stands for. Zero is an
/// agent with nothing since its last summary.
struct CompactResult: Codable, Sendable {
    var compacted: [String: Int]
}

struct FileChanges: Codable, Sendable, Hashable {
    var agent: String
    var takenAt: Int
    var added: [String]
    var changed: [String]
    var removed: [String]

    var count: Int { added.count + changed.count + removed.count }
}

/// Open on the wire, like `TriggerKind`: a kind a newer daemon adds still lists.
enum CantUndoKind: Hashable, Sendable, Codable {
    case message, mail, install, approval, trigger, form
    case other(String)

    init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "message": self = .message
        case "mail": self = .mail
        case "install": self = .install
        case "approval": self = .approval
        case "trigger": self = .trigger
        case "form": self = .form
        case let raw: self = .other(raw)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .message: try container.encode("message")
        case .mail: try container.encode("mail")
        case .install: try container.encode("install")
        case .approval: try container.encode("approval")
        case .trigger: try container.encode("trigger")
        case .form: try container.encode("form")
        case .other(let raw): try container.encode(raw)
        }
    }
}

struct CantUndo: Codable, Sendable, Hashable {
    var messageId: Int
    var kind: CantUndoKind
    var text: String
}

/// `GET …/rewind?from=`: what a rewind from that row takes away, and what it can't.
struct RewindPreview: Codable, Sendable, Hashable {
    var removed: Int
    var files: [FileChanges]
    /// Agents with no snapshot from before that point; the daemon refuses `files` while any is listed.
    var noSnapshot: [String]
    var cantUndo: [CantUndo]
}

struct AgentFile: Codable, Sendable {
    var name: String
    var bytes: Int
    var base64: String
}

struct ComputerResult: Codable, Sendable {
    var action: ComputerActionName
    var image: Base64Image?
    var text: String?
}

struct CommandRequest: Codable, Sendable {
    var command: String
    var timeoutMs: Int?
    var background: Bool?
}

struct CommandResult: Codable, Sendable {
    var exitCode: Int
    var stdout: String
    var stderr: String
    var timedOut: Bool
    var background: Bool
}

struct ToolCall: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var arguments: String
}

enum MessageRole: String, Codable, Sendable, TolerantEnum {
    case user, assistant, tool, unknown
}

struct Message: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var role: MessageRole
    var content: String
    var sender: String?
    var toolCalls: [ToolCall]?
    var toolCallId: String?
    var image: Base64Image?
    /// The owner's thumbs, on an agent's reply only.
    var feedback: MessageFeedback?
    var createdAt: Int
}

enum FeedbackRating: String, Codable, Sendable, Hashable, TolerantEnum {
    case up, down, unknown
}

struct MessageFeedback: Codable, Sendable, Hashable {
    var rating: FeedbackRating
    var reason: String?
}

/// `PUT /api/messages/:id/feedback`. A `nil` rating goes out as `null`, which clears; the daemon
/// refuses a body without one.
struct FeedbackUpdate: Encodable, Equatable {
    var rating: FeedbackRating?
    var reason: String?

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rating, forKey: .rating)
        try container.encodeIfPresent(reason, forKey: .reason)
    }

    private enum CodingKeys: String, CodingKey { case rating, reason }
}

struct FeedbackAnswer: Decodable {
    var feedback: MessageFeedback?
}

struct Schedule: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var agent: String
    var cron: String
    var prompt: String
    var paused: Bool
    var nextRunAt: Int
    var lastRunAt: Int?
    var createdAt: Int
}

enum EventType: String, Codable, Sendable, TolerantEnum {
    case tool_call
    case tool_result
    case state
    case failure
    case restart
    case control
    case schedule_dropped
    case approval
    case stop
    case turn
    case unknown
}

struct ProviderTestResult: Codable, Sendable {
    var ok: Bool
    var reply: String?
    var error: String?
}

/// `MEMORY.md` and today's note. The first is the owner's to rewrite, the second the agent's own.
struct MemoryFiles: Codable, Sendable, Equatable {
    var lasting: String
    var today: String
}

struct UploadResult: Codable, Sendable {
    var path: String
    var bytes: Int
}

struct ForwardFile: Codable, Equatable, Sendable {
    var agent: String
    var path: String
}

/// What the owner passes on: a message, a file from an agent's home, or both, with a note.
/// Absent fields are left out, never sent as `null`.
struct ForwardRequest: Encodable, Equatable, Sendable {
    var messageId: Int?
    var file: ForwardFile?
    var note: String?
}

struct ForwardResult: Decodable, Sendable {
    var message: Message
    var file: UploadResult?
}

enum SearchKind: Hashable, Sendable, Decodable {
    case message, file, screenshot
    case other(String)

    init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "message": self = .message
        case "file": self = .file
        case "screenshot": self = .screenshot
        case let raw: self = .other(raw)
        }
    }
}

/// What `POST /api/search` read a question as. `from`/`to` are epoch ms, inclusive.
struct SearchFilters: Decodable, Sendable, Hashable {
    var kinds: [SearchKind]
    var agent: String?
    var from: Int?
    var to: Int?
    var words: [String]
}

/// One hit and where it came from: a message or screenshot has its thread, a file its path.
struct SearchResult: Decodable, Sendable, Hashable, Identifiable {
    var kind: SearchKind
    /// The agent whose home holds the file, or who wrote the message; absent for the owner.
    var agent: String?
    var conversationId: Int?
    var participants: [String]?
    var messageId: Int?
    var path: String?
    var at: Int
    var snippet: String

    var id: String { "\(kind)|\(conversationId ?? 0)|\(messageId ?? 0)|\(agent ?? "")|\(path ?? "")" }
}

struct SearchAnswer: Decodable, Sendable, Hashable {
    var understoodAs: [String]
    var filters: SearchFilters
    /// False when no model read the question and it went to plain text search.
    var byModel: Bool
    var hits: [SearchResult]
}

enum ApprovalKind: String, Codable, Sendable, TolerantEnum {
    case agent
    case conversation
    /// Anything else the agent wants to do first: spend, send, install, share.
    case action

    /// A kind a newer daemon adds is something to ask about, never a deletion to confirm.
    static var unknown: ApprovalKind { .action }
}

/// A destructive change an agent has asked for and the owner has not answered yet. Nothing is
/// deleted while one of these stands.
struct Approval: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var agent: String
    var conversationId: Int
    var kind: ApprovalKind
    /// One of the daemon's approval categories; every deletion is `delete_files`.
    var category: String
    var target: String
    var amount: String?
    var origin: String?
    var reason: String
    var createdAt: Int
    /// The `request_approval` or `request_deletion` call that asked, which places it in the thread.
    var callId: String?
    /// `approved`, `declined` or `handed_back`; nil while it waits.
    var outcome: String?
    var decidedAt: Int?
}

/// Open on the wire: form items arrive later, and a kind this build doesn't know
/// still lists (as `other`) so the count matches the daemon's.
enum NeedsYouKind: Hashable, Sendable, Codable {
    case approval, question, failure, providerAuth, browserHung, handOver, form, goal
    case other(String)

    init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "approval": self = .approval
        case "question": self = .question
        case "failure": self = .failure
        case "provider_auth": self = .providerAuth
        case "browser_hung": self = .browserHung
        case "hand_over": self = .handOver
        case "form": self = .form
        case "goal": self = .goal
        case let raw: self = .other(raw)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .approval: try container.encode("approval")
        case .question: try container.encode("question")
        case .failure: try container.encode("failure")
        case .providerAuth: try container.encode("provider_auth")
        case .browserHung: try container.encode("browser_hung")
        case .handOver: try container.encode("hand_over")
        case .form: try container.encode("form")
        case .goal: try container.encode("goal")
        case .other(let raw): try container.encode(raw)
        }
    }
}

/// `answer` and `open` happen in the thread; `retry` is the thread's retry of the failed turn;
/// `always` approves and puts the origin or recipient on the agent's pre-approved list;
/// `settings` opens the model settings; `restartBrowser` and `restartDesktop` restart the agent's
/// browser or desktop and tell it to try again; `screen` opens the agent's screen; `takeScreen`
/// takes control of it and opens it.
enum NeedsYouAction: Hashable, Sendable, Codable {
    case approve, always, deny, answer, retry, open, settings, restartBrowser, restartDesktop, screen, takeScreen, fill
    case other(String)

    init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "approve": self = .approve
        case "always": self = .always
        case "deny": self = .deny
        case "answer": self = .answer
        case "retry": self = .retry
        case "open": self = .open
        case "settings": self = .settings
        case "restart_browser": self = .restartBrowser
        case "restart_desktop": self = .restartDesktop
        case "screen": self = .screen
        case "take_screen": self = .takeScreen
        case "fill": self = .fill
        case let raw: self = .other(raw)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .approve: try container.encode("approve")
        case .always: try container.encode("always")
        case .deny: try container.encode("deny")
        case .answer: try container.encode("answer")
        case .retry: try container.encode("retry")
        case .open: try container.encode("open")
        case .settings: try container.encode("settings")
        case .restartBrowser: try container.encode("restart_browser")
        case .restartDesktop: try container.encode("restart_desktop")
        case .screen: try container.encode("screen")
        case .takeScreen: try container.encode("take_screen")
        case .fill: try container.encode("fill")
        case .other(let raw): try container.encode(raw)
        }
    }
}

/// One thing waiting on the owner, listed until it is resolved from wherever.
struct NeedsYouItem: Codable, Sendable, Identifiable, Hashable {
    /// Stable across polls: `approval:<id>`, `question:<message id>`, `failure:<message id>`.
    var id: String
    var kind: NeedsYouKind
    var agent: String
    var conversationId: Int
    var title: String
    var detail: String?
    /// The message the item hangs off: the `ask_owner` call, or the failure line.
    var messageId: Int?
    var approval: Approval?
    var form: FormRequest?
    /// On an imap trigger's login form: the trigger waiting for it.
    var triggerId: Int?
    /// On a `goal` item: the goal whose "next from you" this is.
    var goalId: Int?
    var createdAt: Int
    var actions: [NeedsYouAction]
}

/// A form the daemon read from the agent's page for `request_form`. The origin is the page's own.
struct FormRequest: Codable, Sendable, Hashable {
    var id: Int
    var origin: String
    /// HTTPS or loopback; secret fields are only offered then.
    var secure: Bool
    var reason: String
    var fields: [FormField]
    var unfillable: [UnfillableField]
    var createdAt: Int
}

struct FormField: Codable, Sendable, Hashable, Identifiable {
    struct Option: Codable, Sendable, Hashable {
        var value: String
        var label: String
    }

    var id: String
    var label: String
    /// The input's type, or `select`, `textarea`, `radio`.
    var type: String
    var autocomplete: String?
    var required: Bool
    var options: [Option]?
    var secret: Bool
    /// A value is remembered for this site and fills the field when none is sent.
    var saved: Bool
}

/// `POST /api/agents/:name/forms/:id`: values by field id. A field left out is filled from what
/// is saved for the site, or not touched.
struct FormFill: Encodable, Sendable, Equatable {
    var values: [String: String]
    var remember: Bool

    /// `draft` holds only what the owner entered or picked. A blank text field is left out rather
    /// than sent empty, which would drop its saved value; a checkbox is sent only once flipped,
    /// since the daemon clicks whenever the page's box differs.
    init(fields: [FormField], draft: [String: String], remember: Bool) {
        values = [:]
        for field in fields {
            guard let value = draft[field.id], field.isChoice || !value.isEmpty else { continue }
            values[field.id] = value
        }
        self.remember = remember
    }
}

extension FormField {
    var isChoice: Bool { ["select", "radio", "checkbox"].contains(type) }
}

/// A control that goes to the agent's screen: `cross_origin_frame`, `captcha`, `unknown_widget`,
/// `file`, or `insecure`.
struct UnfillableField: Codable, Sendable, Hashable {
    var label: String
    var reason: String
}

/// One step of the rules ladder, loosest first. A level a newer daemon adds decodes as `.other`.
enum RuleLevel: Hashable, Sendable, Codable {
    case onItsOwn, ifPreApproved, askFirst, handToYou
    case other(String)

    static let ladder: [RuleLevel] = [.onItsOwn, .ifPreApproved, .askFirst, .handToYou]

    init(raw: String) {
        self = Self.ladder.first { $0.raw == raw } ?? .other(raw)
    }

    var raw: String {
        switch self {
        case .onItsOwn: "on_its_own"
        case .ifPreApproved: "if_pre_approved"
        case .askFirst: "ask_first"
        case .handToYou: "hand_to_you"
        case .other(let raw): raw
        }
    }

    init(from decoder: any Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// `GET /api/agents/:name/rules`: a level per approval category, plus per category the domains and
/// recipients the agent may act on without asking.
struct AgentRules: Codable, Sendable, Equatable {
    var levels: [String: RuleLevel]
    var preApproved: [String: [String]]
}

/// `PUT /api/agents/:name/rules`: what is left out keeps its value.
struct AgentRulesUpdate: Encodable, Sendable {
    var levels: [String: RuleLevel]? = nil
    var preApproved: [String: [String]]? = nil
}

struct Routine: Codable, Equatable, Sendable {
    var cron: String
    var prompt: String
}

/// `POST /api/agents/suggest`: a starting point for a new agent. Without a model `byModel` is
/// false and `look` is absent.
struct AgentSuggestion: Decodable, Equatable, Sendable {
    var name: String
    var label: String
    var tagline: String
    var look: String?
    var levels: [String: RuleLevel]
    var routine: Routine?
    var byModel: Bool
}

/// `POST /api/agents`. The description and what came with it are only sent together.
struct AgentCreate: Encodable, Equatable, Sendable {
    var name: String
    var label: String
    var look: String
    var description: String? = nil
    var tagline: String? = nil
    var levels: [String: RuleLevel]? = nil
    var routine: Routine? = nil
}

/// One line of a reply for a list row: markdown marks dropped, fences and newlines folded.
func plainPreview(_ content: String) -> String {
    content
        .replacingOccurrences(of: "```[a-z]*", with: "", options: .regularExpression)
        .replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
        .replacingOccurrences(of: "(?m)^\\s*[-*]\\s+", with: "", options: .regularExpression)
        .replacingOccurrences(of: "[*_`]", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

/// The sender of the row the daemon writes into an agent's own thread when idle work starts.
/// Must match `IDLE_SENDER` in `daemon/src/idle.ts`.
let idleSender = "Idle work"

/// The sender of the rows the daemon writes when a trigger fires or is turned on.
/// Must match `TRIGGER_SENDER` in `daemon/src/triggers.ts`.
let triggerSender = "Trigger"

/// The sender of the daemon's own lines: an approval's outcome, a routine firing, files put back.
/// Must match `SYSTEM_SENDER` in `daemon/src/conversations.ts`.
let systemSender = "System"

/// The line the daemon appends when a rewind puts an agent's files back; older ones have no sender.
/// Must match `restoredLine` in `daemon/src/snapshots.ts`.
let restoredLineStart = "The owner put "
let restoredLineMiddle = "'s files back to how they were at this point in the thread"
/// Mirrors `SHOWN_PREFIX` in the daemon's `recording.ts`: the owner line that hands a recording over.
let shownLinePrefix = "I showed you how to do something on your screen: "

/// Open on the wire, like `NeedsYouKind`: a kind a newer daemon adds still lists.
enum TriggerKind: Hashable, Sendable, Codable {
    case webhook, folder, command, imap
    case other(String)

    init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "webhook": self = .webhook
        case "folder": self = .folder
        case "command": self = .command
        case "imap": self = .imap
        case let raw: self = .other(raw)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .webhook: try container.encode("webhook")
        case .folder: try container.encode("folder")
        case .command: try container.encode("command")
        case .imap: try container.encode("imap")
        case .other(let raw): try container.encode(raw)
        }
    }
}

enum TriggerState: String, Codable, Sendable, TolerantEnum {
    case proposed, on, off, unknown
}

enum TriggerAction: String, Codable, Sendable {
    case on, off, delete
}

struct TriggerConfig: Codable, Sendable, Hashable {
    var path: String?
    var command: String?
    var host: String?
    var port: Int?
    var mailbox: String?
    var everyMinutes: Int?
}

struct TriggerWebhook: Codable, Sendable, Hashable {
    var path: String
    var secret: String
}

/// `GET /api/agents/:name/triggers`. Never carries a mailbox login, only whether one is in.
struct Trigger: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var agent: String
    var kind: TriggerKind
    var config: TriggerConfig
    var reason: String
    var state: TriggerState
    var maxPerHour: Int
    var dropped: Int
    var lastFiredAt: Int?
    var lastError: String?
    var createdAt: Int
    var webhook: TriggerWebhook?
    var hasLogin: Bool?

    var kindWord: String {
        switch kind {
        case .webhook: "Webhook"
        case .folder: "Watched folder"
        case .command: "Check command"
        case .imap: "Mailbox"
        case .other(let raw): raw
        }
    }

    /// What it watches, as the owner would name it; nil for a webhook until it has a URL.
    var watches: String? {
        switch kind {
        case .webhook: webhook?.path
        case .folder: config.path.map { "~/\($0)" }
        case .command: config.command
        case .imap: config.host.map { "\(config.mailbox ?? "INBOX") on \($0)" }
        case .other: nil
        }
    }

    var needsLogin: Bool { kind == .imap && hasLogin != true }

    /// What the owner does to see it fire, once it is on.
    var howToTest: String {
        let every = "It is checked every \(config.everyMinutes ?? 5) minutes."
        switch kind {
        case .webhook: return "Post anything to the URL with the secret in the X-Schermes-Secret header."
        case .folder: return "Drop a file into \(watches ?? "the folder"). \(every)"
        case .command: return "Wait for the command's output to change. \(every) The first check only takes a baseline."
        case .imap: return "Send a mail to \(config.mailbox ?? "INBOX") on \(config.host ?? "the server"). \(every)"
        case .other: return every
        }
    }
}

/// `GET /api/agents/:name/idle`. Conditions stay strings (`IDLE_CONDITIONS` on the daemon), so a
/// condition a newer daemon adds still decodes. Hours are the daemon's clock.
struct IdleSettings: Codable, Sendable, Equatable {
    var enabled: Bool
    var conditions: [String]
    var dailyTokens: Int
    var turnCap: Int
    var modelId: Int?
    var startHour: Int
    var endHour: Int
    var pausedReason: String?

    static let allConditions = ["new_messages", "new_feedback", "memory_size", "stale_files"]
}

/// `PUT /api/agents/:name/idle`: what is left out keeps its value. `modelId: .some(nil)` goes out
/// as `null`, the agent's own model.
struct IdleSettingsUpdate: Encodable, Sendable, Equatable {
    var enabled: Bool? = nil
    var conditions: [String]? = nil
    var dailyTokens: Int? = nil
    var turnCap: Int? = nil
    var modelId: Int?? = nil
    var startHour: Int? = nil
    var endHour: Int? = nil

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(conditions, forKey: .conditions)
        try container.encodeIfPresent(dailyTokens, forKey: .dailyTokens)
        try container.encodeIfPresent(turnCap, forKey: .turnCap)
        if let modelId { try container.encode(modelId, forKey: .modelId) }
        try container.encodeIfPresent(startHour, forKey: .startHour)
        try container.encodeIfPresent(endHour, forKey: .endHour)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, conditions, dailyTokens, turnCap, modelId, startHour, endHour
    }
}

/// `due` matched and has not run: still running, or held back with a `reason`.
enum IdlePassOutcome: Hashable, Sendable, Codable {
    case skipped, due, ran, wasted
    case other(String)

    init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "skipped": self = .skipped
        case "due": self = .due
        case "ran": self = .ran
        case "wasted": self = .wasted
        case let raw: self = .other(raw)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .skipped: try container.encode("skipped")
        case .due: try container.encode("due")
        case .ran: try container.encode("ran")
        case .wasted: try container.encode("wasted")
        case .other(let raw): try container.encode(raw)
        }
    }
}

struct IdlePass: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var agent: String
    var startedAt: Int
    var matched: [String]
    var outcome: IdlePassOutcome
    var tokens: Int
    var endedAt: Int?
    var reason: String?
    var outputs: [IdleOutput]
}

/// Flat on the wire, told apart by `kind`. `resolved` is `dismissed`, `undone` or `accepted`.
struct IdleOutput: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var createdAt: Int
    var resolved: String?
    var kind: Kind

    enum Kind: Hashable, Sendable {
        case memory(before: String, after: String)
        case routine(cron: String, prompt: String)
        case note(text: String)
        case cleanup(approvalId: Int)
        case other(String)
    }

    init(id: Int, createdAt: Int, resolved: String?, kind: Kind) {
        self.id = id
        self.createdAt = createdAt
        self.resolved = resolved
        self.kind = kind
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        createdAt = try container.decode(Int.self, forKey: .createdAt)
        resolved = try container.decodeIfPresent(String.self, forKey: .resolved)
        switch try container.decode(String.self, forKey: .kind) {
        case "memory":
            kind = .memory(
                before: try container.decode(String.self, forKey: .before),
                after: try container.decode(String.self, forKey: .after)
            )
        case "routine":
            kind = .routine(
                cron: try container.decode(String.self, forKey: .cron),
                prompt: try container.decode(String.self, forKey: .prompt)
            )
        case "note": kind = .note(text: try container.decode(String.self, forKey: .text))
        case "cleanup": kind = .cleanup(approvalId: try container.decode(Int.self, forKey: .approvalId))
        case let raw: kind = .other(raw)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(resolved, forKey: .resolved)
        switch kind {
        case .memory(let before, let after):
            try container.encode("memory", forKey: .kind)
            try container.encode(before, forKey: .before)
            try container.encode(after, forKey: .after)
        case .routine(let cron, let prompt):
            try container.encode("routine", forKey: .kind)
            try container.encode(cron, forKey: .cron)
            try container.encode(prompt, forKey: .prompt)
        case .note(let text):
            try container.encode("note", forKey: .kind)
            try container.encode(text, forKey: .text)
        case .cleanup(let approvalId):
            try container.encode("cleanup", forKey: .kind)
            try container.encode(approvalId, forKey: .approvalId)
        case .other(let raw):
            try container.encode(raw, forKey: .kind)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, resolved, kind, before, after, cron, prompt, text, approvalId
    }
}

/// `POST /api/idle/outputs/:id`: memory takes `undo`, a routine `accept` or `dismiss`, a note
/// `dismiss`. A cleanup is answered as its approval.
enum IdleOutputAction: String, Encodable, Sendable {
    case undo, accept, dismiss
}

struct ExecutionEvent: Codable, Sendable, Identifiable {
    var id: Int
    var type: EventType
    var data: [String: JSONValue]
    var createdAt: Int
}

/// `ExecutionEvent.data` is `Record<string, unknown>` on the wire, so it needs a decoder that
/// accepts any JSON and gives it back unchanged.
enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// Open on the wire: a step state a newer daemon adds still shows, as its raw word.
enum GoalStepState: Hashable, Sendable, Codable {
    case todo, doing, done, blocked
    case other(String)

    init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "todo": self = .todo
        case "doing": self = .doing
        case "done": self = .done
        case "blocked": self = .blocked
        case let raw: self = .other(raw)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .todo: try container.encode("todo")
        case .doing: try container.encode("doing")
        case .done: try container.encode("done")
        case .blocked: try container.encode("blocked")
        case .other(let raw): try container.encode(raw)
        }
    }
}

/// `worker`: a task worker on the lead's account with a screen of its own. `agent`: a temporary
/// agent with its own Linux user and desktop.
enum HelperKind: Hashable, Sendable, Codable {
    case worker, agent
    case other(String)

    init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "worker": self = .worker
        case "agent": self = .agent
        case let raw: self = .other(raw)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .worker: try container.encode("worker")
        case .agent: try container.encode("agent")
        case .other(let raw): try container.encode(raw)
        }
    }
}

struct GoalStep: Codable, Sendable, Hashable {
    var text: String
    /// The lead or one of the goal's helpers, by name.
    var owner: String
    var state: GoalStepState
}

struct GoalHelper: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var kind: HelperKind
    var reason: String
    var state: AgentState
    /// Set once the owner chose "Keep as agent": finishing the goal leaves it be.
    var keptAt: Int?
    var createdAt: Int

    var id: String { name }
    var canBeKept: Bool { kind == .agent && keptAt == nil }
}

/// `GET /api/goals`. Kept up by its lead through `update_goal`.
struct Goal: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var title: String
    var lead: String
    var state: String
    var steps: [GoalStep]
    var results: [String]
    var nextFromYou: [String]
    var helpers: [GoalHelper]
    var createdAt: Int
    var updatedAt: Int
    var doneAt: Int?

    var isOpen: Bool { state == "open" }
    var doneSteps: Int { steps.filter { $0.state == .done }.count }
    /// Done steps over all steps, for the ring. A goal without a plan yet is at nothing.
    var progress: Double { steps.isEmpty ? 0 : Double(doneSteps) / Double(steps.count) }
    var progressWords: String { "\(doneSteps) of \(steps.count)" }

    /// Helpers the goal still holds on to: the kept ones are ordinary agents again.
    var temporaryHelpers: [GoalHelper] { isOpen ? helpers.filter { $0.keptAt == nil } : [] }

    func involves(_ agent: String) -> Bool {
        lead == agent || helpers.contains { $0.name == agent && $0.keptAt == nil }
    }
}
