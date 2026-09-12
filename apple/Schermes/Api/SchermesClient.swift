import Foundation

/// Every failure the daemon reports is `{error: string}`, and every one of them is written for a
/// person. They are surfaced as written; only 401 carries meaning of its own, because it is what
/// sends the app back through the Keychain and then to the login screen.
enum SchermesError: LocalizedError {
    case unauthorized
    case daemon(status: Int, message: String)
    case badURL
    case notJSON(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "the session expired"
        case .daemon(_, let message): message
        case .badURL: "that is not a daemon address"
        case .notJSON(let detail): "that is not JSON: \(detail)"
        }
    }
}

extension Error {
    /// A poll torn down with its view arrives as `URLError.cancelled`, not `CancellationError`,
    /// so a screen that showed every error would announce a cancellation on every thread switch.
    /// Nonisolated: the RFB client asks this from its own actor, and the target's default would
    /// otherwise pin it to the one that draws.
    nonisolated var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

/// Which thread is being read. An agent's own thread — a task worker's included — is reached
/// through the agent, because a brand new agent has no conversation row until something is
/// written to it; every other thread is reached by its conversation id.
enum ThreadSource: Hashable, Sendable {
    case agent(String)
    case conversation(Int)

    /// How a thread is named in local storage that has to survive a relaunch.
    var key: String {
        switch self {
        case .agent(let name): "agent:\(name)"
        case .conversation(let id): "conversation:\(id)"
        }
    }
}

/// `GET` and `PUT /api/settings` carry the provider half and the web half in one object, which is
/// `Settings` in `ui/src/api.ts`.
struct DaemonSettings: Decodable, Sendable {
    var provider: ProviderSettings
    var web: WebSettings

    init(from decoder: any Decoder) throws {
        provider = try ProviderSettings(from: decoder)
        web = try WebSettings(from: decoder)
    }
}

struct DaemonSettingsUpdate: Encodable, Sendable {
    var provider: ProviderSettingsUpdate
    var web: WebSettingsUpdate

    func encode(to encoder: any Encoder) throws {
        try provider.encode(to: encoder)
        try web.encode(to: encoder)
    }
}

/// What the settings screen edits. Only made from what the daemon answered, because a save sends
/// every field and one sent from an empty form would blank everything stored. The keys are
/// write-only and start blank.
struct SettingsForm: Equatable {
    var baseUrl: String
    var model: String
    var extraBody: String
    var searchUrl: String
    var apiKey = ""
    var searchKey = ""

    init(_ settings: DaemonSettings) {
        baseUrl = settings.provider.baseUrl
        model = settings.provider.model
        extraBody = settings.provider.extraBody
        searchUrl = settings.web.searchUrl
    }

    /// The daemon writes whatever string it is given, so a blank key is left out rather than sent
    /// as `""`, which would erase it. Every other field always goes: empty is how one is cleared.
    var update: DaemonSettingsUpdate {
        DaemonSettingsUpdate(
            provider: ProviderSettingsUpdate(
                baseUrl: baseUrl,
                model: model,
                apiKey: apiKey.isEmpty ? nil : apiKey,
                extraBody: typedJSON(extraBody)
            ),
            web: WebSettingsUpdate(searchUrl: searchUrl, searchKey: searchKey.isEmpty ? nil : searchKey)
        )
    }
}

/// The iOS keyboard's Smart Punctuation, on by default, turns a typed `"` into a curly quote, and
/// SwiftUI has no switch for it on a text field. Hand-typed JSON is straightened only when that is
/// what makes it parse, so a curly quote inside a valid string value is left alone.
func typedJSON(_ text: String) -> String {
    func parses(_ candidate: String) -> Bool {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(candidate.utf8))) != nil
    }
    guard !parses(text) else { return text }
    let straight = String(text.map { "“”„‟".contains($0) ? "\"" : $0 })
    return parses(straight) ? straight : text
}

/// The MCP box as the daemon's `servers`. Parsed here, as the web UI does, so a typo is named with
/// its line and column instead of arriving as something that is not an array. Empty is no servers.
func mcpServers(fromDraft draft: String) throws -> JSONValue {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return .array([]) }
    do {
        return try JSONDecoder().decode(JSONValue.self, from: Data(typedJSON(text).utf8))
    } catch let DecodingError.dataCorrupted(context) {
        let detail = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
        throw SchermesError.notJSON(detail ?? context.debugDescription)
    }
}

/// No window is the newest page, `before` walks back, `after` asks for only what is new.
struct MessageWindow: Sendable {
    var before: Int? = nil
    var after: Int? = nil
    var limit: Int? = nil

    static let newest = MessageWindow()
}

struct SchermesClient: Sendable {
    var baseURL: URL

    /// The shared cookie storage, so the daemon's session cookie — which carries an expiry, so it
    /// is written to disk rather than dropped at exit — survives a relaunch and the owner is not
    /// asked for a password every cold start.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }()

    /// An agent name is `^[a-z0-9][a-z0-9-]{0,30}$` on the daemon, but it arrives here from a
    /// text field, so it is escaped rather than trusted.
    private static let segment = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")

    /// `percentEncodedPath` rather than `appending(path:)`, which would escape the `%` in an
    /// already-escaped name segment a second time.
    private func url(_ path: String, _ window: MessageWindow? = nil) throws -> URL {
        guard var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { throw SchermesError.badURL }

        var base = parts.percentEncodedPath
        while base.hasSuffix("/") { base.removeLast() }
        parts.percentEncodedPath = base + path

        if let window {
            let items = [
                window.before.map { URLQueryItem(name: "before", value: String($0)) },
                window.after.map { URLQueryItem(name: "after", value: String($0)) },
                window.limit.map { URLQueryItem(name: "limit", value: String($0)) },
            ].compactMap { $0 }
            if !items.isEmpty { parts.queryItems = items }
        }
        guard let built = parts.url else { throw SchermesError.badURL }
        return built
    }

    private static func escape(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: segment) ?? name
    }

    private func send<T: Decodable>(_ method: String, _ url: URL, body: (any Encodable)? = nil) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }

        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // Setup answers 201, create 201 and send 202: the whole 2xx range is success.
        guard (200..<300).contains(status) else {
            if status == 401 { throw SchermesError.unauthorized }
            let reported = try? JSONDecoder().decode(ApiError.self, from: data)
            throw SchermesError.daemon(
                status: status,
                message: reported?.error ?? "the daemon answered \(status)"
            )
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    /// A body with nothing in it, and a `{ok: true}` nobody reads.
    struct Empty: Codable, Sendable {}

    func health() async throws -> HealthResponse {
        try await send("GET", url("/api/health"))
    }

    func setup(password: String) async throws {
        let _: Empty = try await send("POST", url("/api/auth/setup"), body: ["password": password])
    }

    func login(password: String) async throws {
        let _: Empty = try await send("POST", url("/api/auth/login"), body: ["password": password])
    }

    func logout() async throws {
        let _: Empty = try await send("POST", url("/api/auth/logout"), body: Empty())
    }

    func agents() async throws -> [Agent] {
        try await send("GET", url("/api/agents"))
    }

    func createAgent(name: String) async throws -> Agent {
        try await send("POST", url("/api/agents"), body: ["name": name])
    }

    /// A conversation id is a number the daemon handed out, so only the agent half is escaped.
    private static func path(_ source: ThreadSource) -> String {
        switch source {
        case .agent(let name): "/api/agents/\(escape(name))"
        case .conversation(let id): "/api/conversations/\(id)"
        }
    }

    func messagesURL(_ source: ThreadSource, _ window: MessageWindow) throws -> URL {
        try url(Self.path(source) + "/messages", window)
    }

    func messages(_ source: ThreadSource, window: MessageWindow = .newest) async throws -> [Message] {
        try await send("GET", messagesURL(source, window))
    }

    /// Both routes answer 202 with the stored row wrapped as `{message}`.
    func send(_ source: ThreadSource, text: String) async throws -> Message {
        struct Sent: Decodable { let message: Message }
        let sent: Sent = try await send(
            "POST",
            url(Self.path(source) + "/messages"),
            body: ["text": text]
        )
        return sent.message
    }

    func deleteAgent(name: String) async throws {
        let _: Empty = try await send("DELETE", url("/api/agents/\(Self.escape(name))"))
    }

    func deleteConversation(id: Int) async throws {
        let _: Empty = try await send("DELETE", url("/api/conversations/\(id)"))
    }

    func approvals() async throws -> [Approval] {
        try await send("GET", url("/api/approvals"))
    }

    /// The owner's answer. Either way the request is gone afterwards and the agent that asked is
    /// told, in the thread it asked in.
    func decide(approval: Int, approve: Bool) async throws {
        let _: Empty = try await send("POST", url("/api/approvals/\(approval)"), body: ["approve": approve])
    }

    func conversations(agent: String) async throws -> [Conversation] {
        try await send("GET", url("/api/agents/\(Self.escape(agent))/conversations"))
    }

    func live(agent: String) async throws -> LiveReply {
        try await send("GET", url("/api/agents/\(Self.escape(agent))/live"))
    }

    func events(agent: String) async throws -> [ExecutionEvent] {
        try await send("GET", url("/api/agents/\(Self.escape(agent))/events"))
    }

    func schedules(agent: String) async throws -> [Schedule] {
        try await send("GET", url("/api/agents/\(Self.escape(agent))/schedules"))
    }

    func createSchedule(agent: String, cron: String, prompt: String) async throws -> Schedule {
        try await send(
            "POST",
            url("/api/agents/\(Self.escape(agent))/schedules"),
            body: ["cron": cron, "prompt": prompt]
        )
    }

    func pauseSchedule(agent: String, id: Int, paused: Bool) async throws -> Schedule {
        try await send("PATCH", url("/api/agents/\(Self.escape(agent))/schedules/\(id)"), body: ["paused": paused])
    }

    func deleteSchedule(agent: String, id: Int) async throws {
        let _: Empty = try await send("DELETE", url("/api/agents/\(Self.escape(agent))/schedules/\(id)"))
    }

    func settings() async throws -> DaemonSettings {
        try await send("GET", url("/api/settings"))
    }

    func saveSettings(_ update: DaemonSettingsUpdate) async throws -> DaemonSettings {
        try await send("PUT", url("/api/settings"), body: update)
    }

    func mcpServers() async throws -> [McpServerSummary] {
        try await send("GET", url("/api/mcp/servers"))
    }

    /// Replaces the whole list. The secrets in it are never read back, so what goes out is what
    /// the owner typed, never anything a `GET` returned.
    func saveMcpServers(_ servers: JSONValue) async throws -> [McpServerSummary] {
        try await send("PUT", url("/api/mcp/servers"), body: ["servers": servers])
    }

    func testMcpServer(agent: String, server: String) async throws -> McpTestResult {
        try await send(
            "POST",
            url("/api/agents/\(Self.escape(agent))/mcp/\(Self.escape(server))/test"),
            body: Empty()
        )
    }

    /// Who holds a desktop's mouse and keyboard. All three routes answer `{held}`.
    struct ControlState: Decodable, Sendable { let held: Bool }

    func control(agent: String) async throws -> ControlState {
        try await send("GET", url("/api/agents/\(Self.escape(agent))/control"))
    }

    /// Taking is a POST, giving it back a DELETE, exactly as `api.setControl` does it.
    func setControl(agent: String, held: Bool) async throws -> ControlState {
        try await send(held ? "POST" : "DELETE", url("/api/agents/\(Self.escape(agent))/control"))
    }

    /// The agent's desktop, as a byte pipe on the same port and behind the same session guard.
    /// Made on the session the HTTP calls use, so the daemon's cookie rides the upgrade with it.
    func vnc(agent: String) throws -> URLSessionWebSocketTask {
        let route = try url("/api/agents/\(Self.escape(agent))/vnc")
        guard var parts = URLComponents(url: route, resolvingAgainstBaseURL: false) else {
            throw SchermesError.badURL
        }
        parts.scheme = route.scheme == "https" ? "wss" : "ws"
        guard let socket = parts.url else { throw SchermesError.badURL }
        return Self.session.webSocketTask(with: socket)
    }
}
