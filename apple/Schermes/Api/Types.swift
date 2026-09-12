import Foundation

/// One-to-one mirrors of `shared/src/index.ts`: same names, same field names, same optionality.
/// When `shared` changes, this file changes in the same commit.

public let MIN_PASSWORD_LENGTH = 8

struct HealthResponse: Codable, Sendable {
    var status: String
    var setupRequired: Bool
}

struct ProviderSettings: Codable, Sendable {
    var baseUrl: String
    var model: String
    var apiKeySet: Bool
    var extraBody: String
}

struct ProviderSettingsUpdate: Codable, Sendable {
    var baseUrl: String? = nil
    var model: String? = nil
    var apiKey: String? = nil
    var extraBody: String? = nil
}

struct WebSettings: Codable, Sendable {
    var searchUrl: String
    var searchKeySet: Bool
}

struct WebSettingsUpdate: Codable, Sendable {
    var searchUrl: String? = nil
    var searchKey: String? = nil
}

struct McpServerSummary: Codable, Sendable {
    enum Transport: String, Codable, Sendable { case stdio, http }
    var name: String
    var transport: Transport
    var command: String?
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
}

enum AgentState: String, Codable, CaseIterable, Sendable {
    case idle
    case thinking
    case using_computer
    case using_terminal
    case waiting_for_user
    case waiting_for_agent
    case waiting_for_task_worker
    case failed
    case completed
}

struct LiveReply: Codable, Sendable {
    var text: String
    var reasoning: String

    var isEmpty: Bool { text.isEmpty && reasoning.isEmpty }
}

struct Agent: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var display: Int
    var state: AgentState
    var parentId: Int?
    var parentConversationId: Int?
    var createdAt: Int
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

enum MessageRole: String, Codable, Sendable {
    case user, assistant, tool
}

struct Message: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var role: MessageRole
    var content: String
    var sender: String?
    var toolCalls: [ToolCall]?
    var toolCallId: String?
    var image: Base64Image?
    var createdAt: Int
}

struct Conversation: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var participants: [String]
    var createdAt: Int
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

enum EventType: String, Codable, Sendable {
    case tool_call
    case tool_result
    case state
    case failure
    case restart
    case control
    case schedule_dropped
    case approval
}

enum ApprovalKind: String, Codable, Sendable {
    case agent
    case conversation
}

/// A destructive change an agent has asked for and the owner has not answered yet. Nothing is
/// deleted while one of these stands.
struct Approval: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var agent: String
    var conversationId: Int
    var kind: ApprovalKind
    var target: String
    /// The agents in the thread a `conversation` request names. Empty for an `agent` request.
    var participants: [String]
    var reason: String
    var createdAt: Int
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
