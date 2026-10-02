import Foundation

/// Every failure the daemon reports is `{error: string}`, and every one of them is written for a
/// person. They are surfaced as written; only 401 carries meaning of its own, because it is what
/// sends the app back through the Keychain and then to the login screen.
enum SchermesError: LocalizedError {
    case unauthorized
    case daemon(status: Int, message: String)
    case badURL
    case notJSON(String)
    /// Valid JSON that is not a server list. The daemon would say so too; saying it here names
    /// the entry rather than the request.
    case notServers(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "the session expired"
        case .daemon(_, let message): message
        case .badURL: "that is not a daemon address"
        case .notJSON(let detail): "that is not JSON: \(detail)"
        case .notServers(let detail): detail
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

    /// How a thread is named in read marks, here and on the daemon.
    var key: String {
        switch self {
        case .agent(let name): "agent:\(name)"
        case .conversation(let id): "conversation:\(id)"
        }
    }
}

/// `GET` and `PUT /api/settings` carry the web and push halves in one object. The provider fields
/// it still carries are the default model's, which the app edits through `/api/models` instead.
struct DaemonSettings: Decodable, Sendable {
    var web: WebSettings
    var push: PushSettings

    private enum Keys: String, CodingKey { case push }

    init(from decoder: any Decoder) throws {
        web = try WebSettings(from: decoder)
        // Absent on a daemon from before push existed, which is not a reason to refuse the
        // settings screen.
        push = try decoder.container(keyedBy: Keys.self)
            .decodeIfPresent(PushSettings.self, forKey: .push)
            ?? PushSettings(keyId: "", teamId: "", bundleId: "", keySet: false, sandbox: false)
    }
}

struct DaemonSettingsUpdate: Encodable, Sendable {
    var web: WebSettingsUpdate
    var push: PushSettingsUpdate

    func encode(to encoder: any Encoder) throws {
        try web.encode(to: encoder)
        try push.encode(to: encoder)
    }
}

/// What the settings pages edit. Only made from what the daemon answered, because a page's save
/// sends every field it owns and one made from an empty form would blank them. The keys are
/// write-only and start blank.
/// The body of every route that picks a model. `nil` goes out as `null`, never left out: the
/// daemon reads a missing id as no such model.
func modelPick(_ id: Int?) -> [String: Int?] { ["id": id] }

struct SettingsForm: Equatable {
    var searchUrl: String
    var pushKeyId: String
    var searchKey = ""
    var pushKey = ""

    init(_ settings: DaemonSettings) {
        searchUrl = settings.web.searchUrl
        pushKeyId = settings.push.keyId
    }

    /// One page at a time: `PUT /api/settings` keeps every field a body leaves out, so a page
    /// sends its own fields and the other half encodes to nothing.
    ///
    /// The daemon writes whatever string it is given, so a blank key is left out rather than sent
    /// as `""`, which would erase it. Every other field always goes: empty is how one is cleared.
    var webUpdate: DaemonSettingsUpdate {
        DaemonSettingsUpdate(
            web: WebSettingsUpdate(searchUrl: searchUrl, searchKey: searchKey.isEmpty ? nil : searchKey),
            push: PushSettingsUpdate()
        )
    }

    var pushUpdate: DaemonSettingsUpdate {
        DaemonSettingsUpdate(
            web: WebSettingsUpdate(),
            push: PushSettingsUpdate(pushKeyId: pushKeyId, pushKey: pushKey.isEmpty ? nil : pushKey)
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

/// One server as the editor holds it, and exactly the body `PUT /api/mcp/servers/<name>` wants.
/// A secret already stored is the empty string here and goes out as one, which is what keeps it:
/// a key left out of the block would be removed with it, so the whole set is always encoded, an
/// empty block as `{}`. Only the half the transport uses is sent.
struct McpServerDraft: Sendable, Hashable, Encodable {
    /// One `env` variable or header. A list rather than a dictionary so the editor's rows keep
    /// the order they are given.
    struct Secret: Sendable, Hashable {
        var key: String
        var value: String
    }

    var name: String = ""
    var transport: McpServerSummary.Transport = .stdio
    var command: String = ""
    var args: [String] = []
    var url: String = ""
    var secrets: [Secret] = []

    private enum Key: String, CodingKey { case name, command, args, url, env, headers }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(name, forKey: .name)
        let values = Dictionary(secrets.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        switch transport {
        case .stdio:
            try container.encode(command, forKey: .command)
            try container.encode(args, forKey: .args)
            try container.encode(values, forKey: .env)
        case .http:
            try container.encode(url, forKey: .url)
            try container.encode(values, forKey: .headers)
        }
    }
}

private extension JSONValue {
    var text: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

/// The MCP box, or a snippet pasted out of a README, as drafts a form can be filled from. Both
/// shapes are accepted: the bare `[{…}]` array the daemon speaks, and the
/// `{"mcpServers": {"name": {…}}}` object every MCP README prints, whose keys are the names.
/// Parsed here, as the web UI did, so a typo is named with its line and column instead of
/// arriving as something that is not an array. Empty is no servers.
///
/// Only what a draft cannot represent is refused. The name's charset, the url's scheme and how
/// many servers there may be stay the daemon's to judge, so the two cannot drift.
func mcpServers(fromDraft draft: String) throws -> [McpServerDraft] {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return [] }
    let json: JSONValue
    do {
        json = try JSONDecoder().decode(JSONValue.self, from: Data(typedJSON(text).utf8))
    } catch let DecodingError.dataCorrupted(context) {
        let detail = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
        throw SchermesError.notJSON(detail ?? context.debugDescription)
    }

    switch json {
    case .array(let entries):
        return try entries.map { try mcpServer(from: $0, named: nil) }
    case .object(let root):
        guard case .object(let named)? = root["mcpServers"] else {
            throw SchermesError.notServers("that is not a server list or an mcpServers block")
        }
        // A JSON object has no order, so the names are sorted rather than left to the decoder.
        return try named.keys.sorted().map { try mcpServer(from: named[$0]!, named: $0) }
    default:
        throw SchermesError.notServers("that is not a server list or an mcpServers block")
    }
}

/// One server out of a pasted snippet, for the editor sheet, which holds one. Anything else is
/// refused rather than half-read: filling the form from the first entry would drop the rest
/// without saying so.
func mcpServer(fromDraft draft: String) throws -> McpServerDraft {
    let parsed = try mcpServers(fromDraft: draft)
    guard parsed.count == 1 else {
        throw SchermesError.notServers(
            parsed.isEmpty
                ? "that snippet has no server in it"
                : "that snippet has \(parsed.count) servers in it, so add them one at a time"
        )
    }
    return parsed[0]
}

private func mcpServer(from value: JSONValue, named: String?) throws -> McpServerDraft {
    guard case .object(let entry) = value else {
        throw SchermesError.notServers("every server must be an object")
    }
    guard let name = named ?? entry["name"]?.text, !name.isEmpty else {
        throw SchermesError.notServers("every server needs a name")
    }
    let command = entry["command"]?.text
    let url = entry["url"]?.text
    guard (command == nil) != (url == nil) else {
        throw SchermesError.notServers("\(name) must have either a command (stdio) or a url (http), not both")
    }

    guard case .array(let rawArgs) = entry["args"] ?? .array([]) else {
        throw SchermesError.notServers("\(name).args must be an array of strings")
    }
    let args = rawArgs.compactMap(\.text)
    guard args.count == rawArgs.count else {
        throw SchermesError.notServers("\(name).args must be an array of strings")
    }

    let block = command == nil ? "headers" : "env"
    guard case .object(let raw) = entry[block] ?? .object([:]) else {
        throw SchermesError.notServers("\(name).\(block) must be an object of strings")
    }
    let secrets = try raw.keys.sorted().map { key -> McpServerDraft.Secret in
        guard let value = raw[key]?.text else {
            throw SchermesError.notServers("\(name).\(block).\(key) must be a string")
        }
        return McpServerDraft.Secret(key: key, value: value)
    }

    return command == nil
        ? McpServerDraft(name: name, transport: .http, url: url!, secrets: secrets)
        : McpServerDraft(name: name, transport: .stdio, command: command!, args: args, secrets: secrets)
}

/// No window is the newest page, `before` walks back, `after` asks for only what is new.
struct MessageWindow: Sendable {
    var before: Int? = nil
    var after: Int? = nil
    var limit: Int? = nil
    /// False asks for each image's media type without its bytes.
    var images = true

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
        // Every route is live data: a disk cache only wrote each poll, screenshots included, to disk.
        config.urlCache = nil
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
                window.images ? nil : URLQueryItem(name: "images", value: "0"),
            ].compactMap { $0 }
            if !items.isEmpty { parts.queryItems = items }
        }
        guard let built = parts.url else { throw SchermesError.badURL }
        return built
    }

    private static func escape(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: segment) ?? name
    }

    private func send<T: Decodable>(
        _ method: String, _ url: URL, body: (any Encodable)? = nil, headers: [String: String] = [:]
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
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

    /// `attending` tells the daemon the owner is at this screen, so their phone stays quiet.
    func agents(attending: Bool = false) async throws -> [Agent] {
        try await send("GET", url("/api/agents"), headers: attending ? ["x-schermes-attending": "1"] : [:])
    }

    func createAgent(_ request: AgentCreate) async throws -> Agent {
        try await send("POST", url("/api/agents"), body: request)
    }

    /// One model call: a name, label, look, rules and routine for what the owner described.
    func suggestAgent(description: String) async throws -> AgentSuggestion {
        try await send("POST", url("/api/agents/suggest"), body: ["description": description])
    }

    /// Changes what the owner sees and what the agent is told it is: the label, the avatar, the
    /// profile. A `slug` moves the agent to a new name: its Linux user, home and desktop go with
    /// it, so the daemon refuses one while the agent is in a turn. A blank profile clears it.
    func updateAgent(name: String, slug: String? = nil, label: String? = nil, look: String? = nil, profile: String? = nil) async throws -> Agent {
        var body: [String: String] = [:]
        if let slug { body["name"] = slug }
        if let label { body["label"] = label }
        if let look { body["look"] = look }
        if let profile { body["profile"] = profile }
        return try await send("PATCH", url("/api/agents/\(Self.escape(name))"), body: body)
    }

    /// Ends the turn an agent is in. `stopped` is false when nothing was running, which is not
    /// an error: the owner pressed the button as the turn ended by itself.
    func stop(agent: String) async throws -> Bool {
        struct Stopped: Decodable { let stopped: Bool }
        let answer: Stopped = try await send("POST", url("/api/agents/\(Self.escape(agent))/stop"), body: Empty())
        return answer.stopped
    }

    /// A file for the agent's `~/uploads`. Base64 in JSON, the way a screenshot travels.
    func upload(agent: String, name: String, data: Data) async throws -> UploadResult {
        try await send(
            "POST",
            url("/api/agents/\(Self.escape(agent))/uploads"),
            body: ["name": name, "base64": data.base64EncodedString()]
        )
    }

    /// Passes a message or a file on to `agent`, which answers it in its own thread.
    func forward(to agent: String, _ request: ForwardRequest) async throws -> ForwardResult {
        try await send("POST", url("/api/agents/\(Self.escape(agent))/forward"), body: request)
    }

    /// A file from inside the agent's home, as the agent named it: `~/…` or the full path.
    func file(agent: String, path: String) async throws -> AgentFile {
        guard var parts = URLComponents(url: try url("/api/agents/\(Self.escape(agent))/files"), resolvingAgainstBaseURL: false)
        else { throw SchermesError.badURL }
        parts.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let built = parts.url else { throw SchermesError.badURL }
        return try await send("GET", built)
    }

    func memory(agent: String) async throws -> MemoryFiles {
        try await send("GET", url("/api/agents/\(Self.escape(agent))/memory"))
    }

    func saveMemory(agent: String, lasting: String) async throws -> MemoryFiles {
        try await send("PUT", url("/api/agents/\(Self.escape(agent))/memory"), body: ["lasting": lasting])
    }

    /// A question over every thread, every agent's files and the text in their screenshots.
    func ask(_ question: String) async throws -> SearchAnswer {
        try await send("POST", url("/api/search"), body: ["q": question])
    }

    func providers() async throws -> [ProviderEntry] {
        try await send("GET", url("/api/providers"))
    }

    func createProvider(_ update: ProviderUpdate) async throws -> ProviderEntry {
        try await send("POST", url("/api/providers"), body: update)
    }

    func updateProvider(id: Int, _ update: ProviderUpdate) async throws -> ProviderEntry {
        try await send("PUT", url("/api/providers/\(id)"), body: update)
    }

    func deleteProvider(id: Int) async throws {
        let _: Empty = try await send("DELETE", url("/api/providers/\(id)"))
    }

    func models() async throws -> [ModelEntry] {
        try await send("GET", url("/api/models"))
    }

    func createModel(_ update: ModelUpdate) async throws -> ModelEntry {
        try await send("POST", url("/api/models"), body: update)
    }

    func updateModel(id: Int, _ update: ModelUpdate) async throws -> ModelEntry {
        try await send("PUT", url("/api/models/\(id)"), body: update)
    }

    func deleteModel(id: Int) async throws {
        let _: Empty = try await send("DELETE", url("/api/models/\(id)"))
    }

    func setDefaultModel(id: Int) async throws -> [ModelEntry] {
        try await send("PUT", url("/api/models/default"), body: modelPick(id))
    }

    /// `nil` leaves no backup.
    func setBackupModel(id: Int?) async throws -> [ModelEntry] {
        try await send("PUT", url("/api/models/backup"), body: modelPick(id))
    }

    /// One model call against what is stored for that entry, no tools.
    func testModel(id: Int) async throws -> ProviderTestResult {
        try await send("POST", url("/api/models/\(id)/test"), body: Empty())
    }

    /// `nil` puts the agent back on the default. Answers the agent as it now is.
    func assignModel(agent: String, id: Int?) async throws -> Agent {
        try await send("PUT", url("/api/agents/\(Self.escape(agent))/model"), body: modelPick(id))
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

    /// Every approval asked in the thread, answered ones included.
    func approvals(_ source: ThreadSource) async throws -> [Approval] {
        try await send("GET", url(Self.path(source) + "/approvals"))
    }

    /// Removes everything from `from` on. With `retry`, the agents answer the message left last again.
    /// With `files`, every agent in the thread also gets its home back as it was at that point.
    func rewind(_ source: ThreadSource, from: Int, retry: Bool, files: Bool = false) async throws {
        struct Done: Decodable { let ok: Bool }
        struct Body: Encodable { var from: Int; var retry: Bool; var files: Bool }
        let _: Done = try await send(
            "POST",
            url(Self.path(source) + "/rewind"),
            body: Body(from: from, retry: retry, files: files)
        )
    }

    func rewindPreview(_ source: ThreadSource, from: Int) async throws -> RewindPreview {
        try await send("GET", url(Self.path(source) + "/rewind").appending(queryItems: [URLQueryItem(name: "from", value: String(from))]))
    }

    /// Folds everything since the last summary into a new one, for every agent in the thread, the
    /// way a turn does when the thread is past its budget. Refused while any of them is mid-turn.
    func compact(_ source: ThreadSource) async throws -> CompactResult {
        try await send("POST", url(Self.path(source) + "/compact"), body: Empty())
    }

    /// Both routes answer 202 with the stored row wrapped as `{message}`. An image rides inline
    /// as base64, the way a screenshot does, and reaches the model as what the owner saw.
    func send(_ source: ThreadSource, text: String, image: Base64Image? = nil) async throws -> Message {
        struct Sent: Decodable { let message: Message }
        struct Outgoing: Encodable { var text: String; var image: Base64Image? }
        let sent: Sent = try await send(
            "POST",
            url(Self.path(source) + "/messages"),
            body: Outgoing(text: text, image: image)
        )
        return sent.message
    }

    func devices() async throws -> [Device] {
        try await send("GET", url("/api/devices"))
    }

    #if !SCHERMES_EXTENSION
    /// This device, so the daemon can reach it when the app is not running. Upserted by token.
    /// The build says who it is alongside, which is what the daemon's push settings are made of.
    func registerDevice(_ registration: PushRegistration, token: String) async throws {
        var body = ["token": token, "platform": registration.platform, "bundleId": registration.bundleId, "environment": registration.environment]
        if let teamId = registration.teamId { body["teamId"] = teamId }
        let _: Empty = try await send("POST", url("/api/devices"), body: body)
    }
    #endif

    func unregisterDevice(token: String) async throws {
        let _: Empty = try await send("DELETE", url("/api/devices/\(Self.escape(token))"))
    }

    /// One push to every registered device, from the settings screen.
    func testPush() async throws -> PushTestResult {
        try await send("POST", url("/api/settings/push/test"), body: Empty())
    }

    func deleteAgent(name: String) async throws {
        let _: Empty = try await send("DELETE", url("/api/agents/\(Self.escape(name))"))
    }

    func deleteConversation(id: Int) async throws {
        let _: Empty = try await send("DELETE", url("/api/conversations/\(id)"))
    }

    func needsYou() async throws -> [NeedsYouItem] {
        try await send("GET", url("/api/needs-you"))
    }

    func readMarks() async throws -> [String: Int] {
        try await send("GET", url("/api/read"))
    }

    func markRead(_ source: ThreadSource, through id: Int) async throws {
        struct Mark: Encodable { let thread: String; let messageId: Int }
        let _: Empty = try await send("PUT", url("/api/read"), body: Mark(thread: source.key, messageId: id))
    }

    /// The owner's answer. Either way the request is gone afterwards and the agent that asked is
    /// told, in the thread it asked in.
    /// `always` also puts the approval's origin or recipient on the agent's pre-approved list.
    func decide(approval: Int, approve: Bool, always: Bool = false) async throws {
        let _: Empty = try await send(
            "POST", url("/api/approvals/\(approval)"), body: ["approve": approve, "always": always]
        )
    }

    /// A notification button's answer to a Needs you item, found by id alone.
    func act(onNeedsYou id: String, _ action: NeedsYouAction) async throws {
        let _: Empty = try await send(
            "POST", url("/api/needs-you/\(Self.escape(id))/action"), body: ["action": action]
        )
    }

    func conversations(agent: String) async throws -> [Conversation] {
        try await send("GET", url("/api/agents/\(Self.escape(agent))/conversations"))
    }

    func live(agent: String) async throws -> LiveReply {
        try await send("GET", url("/api/agents/\(Self.escape(agent))/live"))
    }

    /// "Retry now" skips the wait of a model call; "Use backup model" moves this turn to the backup.
    func retryModel(agent: String, useBackup: Bool) async throws {
        let _: Empty = try await send(
            "POST", url("/api/agents/\(Self.escape(agent))/retry"), body: ["action": useBackup ? "backup" : "now"]
        )
    }

    /// Kills the agent's hung browser, or restarts its whole desktop, and tells it to try again.
    func fillForm(agent: String, id: Int, fill: FormFill) async throws {
        let _: Empty = try await send("POST", url("/api/agents/\(Self.escape(agent))/forms/\(id)"), body: fill)
    }

    func restartBrowser(agent: String, desktop: Bool) async throws {
        let _: Empty = try await send(
            "POST", url("/api/agents/\(Self.escape(agent))/browser/restart"), body: ["what": desktop ? "desktop" : "browser"]
        )
    }

    /// The newest `limit` events, oldest first. The log grows for the life of the install, so a
    /// screen that polls it asks for the tail.
    func events(agent: String, limit: Int) async throws -> [ExecutionEvent] {
        try await send("GET", url("/api/agents/\(Self.escape(agent))/events", MessageWindow(limit: limit)))
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

    func rules(agent: String) async throws -> AgentRules {
        try await send("GET", url("/api/agents/\(Self.escape(agent))/rules"))
    }

    func setRules(agent: String, _ update: AgentRulesUpdate) async throws -> AgentRules {
        try await send("PUT", url("/api/agents/\(Self.escape(agent))/rules"), body: update)
    }

    func goals() async throws -> [Goal] {
        try await send("GET", url("/api/goals"))
    }

    func goal(id: Int) async throws -> Goal {
        try await send("GET", url("/api/goals/\(id)"))
    }

    /// Removes the helpers nobody kept. Refused (409) while one of them is mid-turn.
    func finishGoal(id: Int) async throws -> Goal {
        try await send("POST", url("/api/goals/\(id)/finish"), body: Empty())
    }

    func deleteGoal(id: Int) async throws {
        let _: Empty = try await send("DELETE", url("/api/goals/\(id)"))
    }

    /// Promotes a temporary helper to an agent of its own. Refused for a worker, which has no account.
    func keepHelper(goal: Int, name: String) async throws -> Goal {
        try await send("POST", url("/api/goals/\(goal)/helpers/\(Self.escape(name))/keep"), body: Empty())
    }

    func triggers(agent: String) async throws -> [Trigger] {
        try await send("GET", url("/api/agents/\(Self.escape(agent))/triggers"))
    }

    /// The trigger as it now stands; nil once deleted.
    func actOnTrigger(id: Int, action: TriggerAction) async throws -> Trigger? {
        if action == .delete {
            let _: Empty = try await send("POST", url("/api/triggers/\(id)"), body: ["action": action])
            return nil
        }
        return try await send("POST", url("/api/triggers/\(id)"), body: ["action": action])
    }

    /// Where an outside service posts a webhook trigger: the daemon's own address plus the path.
    func hookURL(_ webhook: TriggerWebhook) -> URL? {
        try? url(webhook.path)
    }

    func idle(agent: String) async throws -> IdleSettings {
        try await send("GET", url("/api/agents/\(Self.escape(agent))/idle"))
    }

    func setIdle(agent: String, _ update: IdleSettingsUpdate) async throws -> IdleSettings {
        try await send("PUT", url("/api/agents/\(Self.escape(agent))/idle"), body: update)
    }

    /// Every agent's idle passes that started at or after `since` (ms), with their outputs.
    func idlePasses(since: Int) async throws -> [IdlePass] {
        try await send("GET", url("/api/idle/passes").appending(queryItems: [URLQueryItem(name: "since", value: String(since))]))
    }

    /// Answers the output as it now stands, resolved.
    func resolveIdleOutput(id: Int, _ action: IdleOutputAction) async throws -> IdleOutput {
        try await send("POST", url("/api/idle/outputs/\(id)"), body: ["action": action])
    }

    /// Answers the feedback as the daemon stored it, `nil` once cleared.
    func setFeedback(message id: Int, _ update: FeedbackUpdate) async throws -> MessageFeedback? {
        let answer: FeedbackAnswer = try await send("PUT", url("/api/messages/\(id)/feedback"), body: update)
        return answer.feedback
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

    /// Adds or changes one server and answers the whole list, so a screen refreshes in one trip.
    /// A secret the draft carries blank keeps its stored value.
    func putMcpServer(_ server: McpServerDraft) async throws -> [McpServerSummary] {
        try await send("PUT", url("/api/mcp/servers/\(Self.escape(server.name))"), body: server)
    }

    func deleteMcpServer(_ name: String) async throws {
        let _: Empty = try await send("DELETE", url("/api/mcp/servers/\(Self.escape(name))"))
    }

    func testMcpServer(agent: String, server: String) async throws -> McpTestResult {
        try await send(
            "POST",
            url("/api/agents/\(Self.escape(agent))/mcp/\(Self.escape(server))/test"),
            body: Empty()
        )
    }

    /// Who holds a desktop's mouse and keyboard. All three routes answer `{held}`; `handOver` says
    /// the agent asked for hands and giving the screen back will tell it.
    struct ControlState: Decodable, Sendable {
        let held: Bool
        var handOver: Bool?
        /// Present only while "Show the agent how" records.
        var recording: RecordingState?
    }

    struct RecordingState: Decodable, Sendable, Equatable {
        let startedAt: Int
        let steps: Int
        let shots: Int
        let secret: Bool
        var truncated: Bool?
    }

    /// Takes the screen and records the owner's hands; giving the screen back hands it to the agent.
    func startRecording(agent: String) async throws -> ControlState {
        try await send("POST", url("/api/agents/\(Self.escape(agent))/recording"))
    }

    func setRecordingSecret(agent: String, secret: Bool) async throws -> ControlState {
        struct Body: Encodable { let secret: Bool }
        return try await send("PUT", url("/api/agents/\(Self.escape(agent))/recording"), body: Body(secret: secret))
    }

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
