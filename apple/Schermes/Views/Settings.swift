import SwiftUI

/// The daemon's configuration, one page per category. Each page with fields loads the whole
/// settings object and saves only the fields it owns: `PUT /api/settings` keeps every field a
/// body leaves out.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case model
    case web
    case notifications
    case plugins
    case daemon
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .model: "Model"
        case .web: "Web search"
        case .notifications: "Notifications"
        case .plugins: "Plugins"
        case .daemon: "Daemon"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .model: "brain"
        case .web: "magnifyingglass"
        case .notifications: "bell.badge"
        case .plugins: "puzzlepiece.extension"
        case .daemon: "server.rack"
        case .about: "info.circle"
        }
    }
}

/// A page carries no navigation of its own: on iOS it is pushed onto the sheet's stack, on the Mac
/// it sits bare inside a toolbar tab.
@ViewBuilder func settingsPage(_ category: SettingsCategory, session: Session) -> some View {
    switch category {
    case .model: ModelPage(session: session)
    case .web: WebSearchPage(session: session)
    case .notifications: NotificationsPage(session: session)
    case .plugins: PluginsPage(session: session)
    case .daemon: DaemonPage(session: session)
    case .about: AboutPage()
    }
}

#if os(iOS)
/// iOS has no `Settings` scene: the sidebar's gear opens this sheet and each row pushes its page.
struct SettingsSheet: View {
    let session: Session

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(SettingsCategory.allCases) { category in
                NavigationLink {
                    settingsPage(category, session: session)
                } label: {
                    Label(category.title, systemImage: category.symbol)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#else
/// The body of the Mac's `Settings` scene, which is what gives the app ⌘, and the app menu's
/// Settings… item. Its own minimum size: a scene has no sheet to take one from.
struct SettingsWindow: View {
    let session: Session

    var body: some View {
        TabView {
            ForEach(SettingsCategory.allCases) { category in
                Tab(category.title, systemImage: category.symbol) {
                    settingsPage(category, session: session)
                }
            }
        }
        .frame(minWidth: 540, minHeight: 600)
    }
}
#endif

/// Load, edit, save: the shell the three pages with fields share. Nothing is editable until the
/// daemon has answered, because a form made before that would save its own emptiness.
private struct FieldPage<Fields: View>: View {
    let session: Session
    let title: String
    let update: KeyPath<SettingsForm, DaemonSettingsUpdate>
    let footer: String
    var afterSave: () -> Void = {}
    @ViewBuilder let fields: (Binding<SettingsForm>, DaemonSettings, Bool) -> Fields

    @State private var stored: DaemonSettings?
    @State private var form: SettingsForm?
    @State private var trouble: String?
    @State private var saving = false
    @State private var saved = false

    var body: some View {
        Group {
            if let stored, let form = Binding($form) {
                let unchanged = form.wrappedValue == SettingsForm(stored)
                Form {
                    fields(form, stored, unchanged)

                    Section {
                        Button(saving ? "Saving…" : "Save", action: save)
                            .disabled(saving || unchanged)
                        if let trouble {
                            Text(trouble)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        } else if saved && unchanged {
                            Text("Saved.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text(footer)
                    }
                }
                .formStyle(.grouped)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            } else if let trouble {
                ContentUnavailableView(
                    "Settings could not be read",
                    systemImage: "exclamationmark.triangle",
                    description: Text(trouble)
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    private func load() async {
        do {
            let answer = try await session.run { try await $0.settings() }
            stored = answer
            form = SettingsForm(answer)
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }

    /// The daemon checks every field before it writes any, so a refusal changes nothing there and
    /// nothing here: the form keeps what was typed and the refusal is shown as it came.
    private func save() {
        guard let form, !saving else { return }
        saving = true
        saved = false
        trouble = nil
        Task {
            do {
                let answer = try await session.run { try await $0.saveSettings(form[keyPath: update]) }
                stored = answer
                self.form = SettingsForm(answer)
                saved = true
                afterSave()
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            saving = false
        }
    }
}

/// The provider the agents think with. The key is write-only: a stored one shows as stored, never
/// as itself.
private struct ModelPage: View {
    let session: Session

    @State private var testing = false
    @State private var tested: ProviderTestResult?

    var body: some View {
        FieldPage(
            session: session,
            title: SettingsCategory.model.title,
            update: \.modelUpdate,
            footer: "The key is encrypted on the daemon and never comes back out. Leave it blank to keep the one stored.",
            afterSave: { tested = nil }
        ) { form, stored, unchanged in
            Section {
                LabeledContent("Base URL") {
                    TextField("Base URL", text: form.baseUrl, prompt: Text(verbatim: "https://api.example.com/v1"))
                        #if os(iOS)
                        .keyboardType(.URL)
                        #endif
                        .rowField()
                }
                LabeledContent("Model") {
                    TextField("Model", text: form.model)
                        .rowField()
                }
                LabeledContent("API key") {
                    SecureField("API key", text: form.apiKey, prompt: Text(stored.provider.apiKeySet ? "Stored" : "Not set"))
                        .rowField()
                }
                // Tests what is stored, so it waits for a save: a test of the form as typed would
                // be a second path that sends the key.
                Button(testing ? "Testing…" : "Test connection", action: test)
                    .buttonStyle(.borderless)
                    .disabled(testing || !unchanged || !stored.provider.apiKeySet)
                if let tested {
                    Label(
                        tested.ok
                            ? ((tested.reply ?? "").isEmpty ? "Answered" : "Answered: \(tested.reply ?? "")")
                            : (tested.error ?? "Could not be reached"),
                        systemImage: tested.ok ? "checkmark.circle" : "xmark.octagon"
                    )
                    .font(.footnote)
                    .foregroundStyle(tested.ok ? Color.secondary : Color.red)
                    .textSelection(.enabled)
                }
            } header: {
                Text("Provider")
            } footer: {
                Text("One OpenAI-compatible endpoint with tool calling and vision. Save, then test: one short model call, no tools.")
            }

            Section {
                TextField(
                    "Extra request fields",
                    text: form.extraBody,
                    prompt: Text(verbatim: #"{"reasoning":{"effort":"high"}}"#),
                    axis: .vertical
                )
                .font(.callout.monospaced())
                .lineLimit(1...6)
                .rowField()
            } header: {
                Text("Extra request fields")
            } footer: {
                Text("A JSON object merged into every model request: routing, reasoning effort, token caps. Empty for none.")
            }
        }
    }

    private func test() {
        guard !testing else { return }
        testing = true
        tested = nil
        Task {
            do {
                tested = try await session.run { try await $0.testProvider() }
            } catch {
                if !error.isCancellation {
                    tested = ProviderTestResult(ok: false, reply: nil, error: error.localizedDescription)
                }
            }
            testing = false
        }
    }
}

/// The endpoint `web_search` asks and the token it carries.
private struct WebSearchPage: View {
    let session: Session

    var body: some View {
        FieldPage(
            session: session,
            title: SettingsCategory.web.title,
            update: \.webUpdate,
            footer: "The key is encrypted on the daemon and never comes back out. Leave it blank to keep the one stored."
        ) { form, stored, _ in
            Section {
                LabeledContent("Endpoint") {
                    TextField("Endpoint", text: form.searchUrl, prompt: Text("Built-in Brave"))
                        #if os(iOS)
                        .keyboardType(.URL)
                        #endif
                        .rowField()
                }
                LabeledContent("Key") {
                    SecureField("Search key", text: form.searchKey, prompt: Text(stored.web.searchKeySet ? "Stored" : "Not set"))
                        .rowField()
                }
            } footer: {
                Text("A Brave Search subscription token. Without one `web_search` refuses and says so; `web_fetch` needs no key. Set the endpoint only for a proxy or a mirror that answers in Brave's shape.")
            }
        }
    }
}

/// The APNs key the daemon pushes with, and the devices it has to push to. The ids are not
/// typed: the build that registers a device reports its own, and a key mounted into the
/// container is stored at boot, so this page is a status screen unless a key has to be pasted.
private struct NotificationsPage: View {
    let session: Session

    @State private var devices: [Device] = []
    @State private var pushing = false
    @State private var pushed: PushTestResult?
    @Environment(PushRegistration.self) private var registration

    var body: some View {
        FieldPage(
            session: session,
            title: SettingsCategory.notifications.title,
            update: \.pushUpdate,
            footer: "The key is encrypted on the daemon and never comes back out. Leave it blank to keep the one stored.",
            afterSave: { pushed = nil }
        ) { form, stored, unchanged in
            Section {
                LabeledContent("App", value: stored.push.bundleId.isEmpty ? "Not yet registered" : stored.push.bundleId)
                LabeledContent("Team", value: stored.push.teamId.isEmpty ? "Not yet registered" : stored.push.teamId)
                LabeledContent("Gateway", value: stored.push.bundleId.isEmpty ? "Not yet registered" : stored.push.sandbox ? "Sandbox (development build)" : "Production")
                LabeledContent("Devices", value: deviceLine)
                Button(pushing ? "Sending…" : "Send test push", action: testPush)
                    .buttonStyle(.borderless)
                    .disabled(pushing || !unchanged || !stored.push.keySet || devices.isEmpty)
                if let pushed {
                    Label(
                        pushed.ok ? "Sent to \(pushed.sent) device\(pushed.sent == 1 ? "" : "s")" : (pushed.error ?? "Could not send"),
                        systemImage: pushed.ok ? "checkmark.circle" : "xmark.octagon"
                    )
                    .font(.footnote)
                    .foregroundStyle(pushed.ok ? Color.secondary : Color.red)
                    .textSelection(.enabled)
                }
            } footer: {
                Text("The daemon pushes to your phone when an agent finishes or asks something. The app, team and gateway come from the build that registered a device; open the app on the phone and they fill in.")
            }

            Section {
                LabeledContent("Key ID") {
                    TextField("Key ID", text: form.pushKeyId, prompt: Text("ABC123DEFG"))
                        .rowField()
                }
                TextField(
                    "Key (.p8)",
                    text: form.pushKey,
                    prompt: Text(stored.push.keySet ? "Stored" : "Not set"),
                    axis: .vertical
                )
                .font(.caption.monospaced())
                .lineLimit(1...4)
                .rowField()
            } header: {
                Text(stored.push.keySet ? "Key" : "Key (not set)")
            } footer: {
                Text("Mount the AuthKey_<KEYID>.p8 from the Apple Developer portal into the container and point SCHERMES_APNS_KEY_FILE at it; then nothing here needs filling in. Paste it only when you cannot: blank keeps the stored one.")
            }
        }
        .task(id: session.registeredDevice) {
            devices = (try? await session.run { try await $0.devices() }) ?? []
        }
    }

    private var deviceLine: String {
        let count = devices.isEmpty ? "None registered" : "\(devices.count) registered"
        let mine = registration.token.map { token in devices.contains { $0.token == token } } ?? false
        if mine { return count + ", this one included" }
        if let failure = registration.failure { return count + " · this device: \(failure)" }
        return count + (registration.token == nil ? " · this device: no APNs token yet" : " · this device: not registered yet")
    }

    private func testPush() {
        guard !pushing else { return }
        pushing = true
        pushed = nil
        Task {
            do {
                pushed = try await session.run { try await $0.testPush() }
            } catch {
                if !error.isCancellation { pushed = PushTestResult(ok: false, sent: 0, error: error.localizedDescription) }
            }
            pushing = false
        }
    }
}

/// Which daemon this is talking to, and the two ways to stop.
private struct DaemonPage: View {
    let session: Session

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                LabeledContent("Address", value: session.client?.baseURL.absoluteString ?? "none")
                    .textSelection(.enabled)
                // The address only: the password stays in the Keychain under it, so coming back
                // to this daemon does not ask for one again.
                Button("Use a different daemon") {
                    dismiss()
                    session.forgetServer()
                }
                .buttonStyle(.borderless)
            }

            Section {
                Button("Log out", role: .destructive) {
                    dismiss()
                    Task { await session.logOut() }
                }
                .buttonStyle(.borderless)
            } footer: {
                Text("Logging out keeps the address and the stored password; using a different daemon keeps neither.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsCategory.daemon.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private extension View {
    /// A Mac form draws a field's own title beside it, which next to the row's label is the name
    /// twice. An iOS form shows only the prompt, and a field with none falls back to its title.
    @ViewBuilder func rowField() -> some View {
        #if os(macOS)
        labelsHidden()
        #else
        self
        #endif
    }
}

/// The owner's MCP servers, which the reference calls plugins: one row per server, an editor for
/// adding or changing one, and a connection test run as one agent because a stdio server starts as
/// that agent's Linux user.
struct PluginsPage: View {
    let session: Session

    @State private var servers: [McpServerSummary]?
    /// Permanent agents only: a task worker has no Linux user of its own to test as. Loaded here
    /// rather than handed in, because the Mac's Settings scene is outside the console.
    @State private var agents: [Agent] = []
    @State private var chosen: String?
    @State private var results: [String: McpTestResult] = [:]
    @State private var testing: Set<String> = []
    @State private var editing: ServerEdit?
    @State private var removing: McpServerSummary?
    @State private var trouble: String?

    private var testAs: String? { chosen ?? agents.first?.name }

    var body: some View {
        Form {
            Section {
                if let servers {
                    if servers.isEmpty {
                        Text("No servers configured.").foregroundStyle(.secondary)
                    }
                    ForEach(servers, id: \.name) { server in
                        ServerRow(
                            server: server,
                            result: results[server.name],
                            testing: testing.contains(server.name),
                            canTest: testAs != nil,
                            onTest: { test(server.name) },
                            onEdit: { editing = ServerEdit(server: server) },
                            onDelete: { removing = server }
                        )
                        #if os(iOS)
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { removing = server }
                        }
                        #endif
                    }
                } else if let trouble {
                    Text(trouble).foregroundStyle(.red)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }

                // A row rather than a toolbar item: on the Mac this page sits in a `Settings`
                // scene whose toolbar is already the category tabs.
                Button("Add server", systemImage: "plus") { editing = ServerEdit() }
                    .buttonStyle(.borderless)
                    .disabled(servers == nil)

                if let trouble, servers != nil {
                    Text(trouble)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Configured")
            } footer: {
                Text("Owner-wide. Every server is connected at the start of an agent's turn and its tools are offered as `mcp__<server>__<tool>`.")
            }

            Section {
                if agents.isEmpty {
                    Text("Create an agent to test a server as.").foregroundStyle(.secondary)
                } else {
                    Picker("Test as", selection: Binding(get: { testAs }, set: { chosen = $0; results = [:] })) {
                        ForEach(agents) { Text($0.title).tag(Optional($0.name)) }
                    }
                }
            } footer: {
                Text("A stdio server is started as that agent's Linux user, so a test says what that agent would get.")
            }
        }
        .formStyle(.grouped)
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
        .navigationTitle(SettingsCategory.plugins.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .sheet(item: $editing) { edit in
            ServerSheet(session: session, existing: edit.server) { list in
                servers = list
                // Every row's last test describes a server as it was; one of them just changed.
                results = [:]
            }
        }
        .confirmationDialog(
            removing.map { "Delete \($0.name)?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { server in
            Button("Delete", role: .destructive) { remove(server) }
            Button("Cancel", role: .cancel) {}
        } message: { server in
            Text("Its tools stop being offered to every agent, and the \(server.transport == .stdio ? "environment" : "header") values it carries are deleted with it.")
        }
    }

    private func load() async {
        do {
            servers = try await session.run { try await $0.mcpServers() }
            agents = (try? await session.run { try await $0.agents() })?.filter { $0.parentId == nil } ?? []
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }

    private func remove(_ server: McpServerSummary) {
        trouble = nil
        Task {
            do {
                try await session.run { try await $0.deleteMcpServer(server.name) }
                servers?.removeAll { $0.name == server.name }
                results[server.name] = nil
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
        }
    }

    private func test(_ server: String) {
        guard let agent = testAs else { return }
        testing.insert(server)
        results[server] = nil
        Task {
            do {
                results[server] = try await session.run {
                    try await $0.testMcpServer(agent: agent, server: server)
                }
            } catch {
                // The route's own refusals, no such agent or no such server, are failed requests
                // rather than failed tests, and read the same way on the row.
                if !error.isCancellation {
                    results[server] = McpTestResult(ok: false, tools: [], error: error.localizedDescription)
                }
            }
            testing.remove(server)
        }
    }
}

/// What the editor sheet is open on: an existing server, or nothing at all for Add. The id is the
/// sheet's, not the server's, so opening Add straight after an Edit is a new sheet.
private struct ServerEdit: Identifiable {
    let id = UUID()
    var server: McpServerSummary? = nil
}

/// One `env` variable or header while it is being edited. Identified by a token of its own: two
/// rows can be blank at once and neither may take the other's focus.
private struct SecretRow: Identifiable {
    let id = UUID()
    var key = ""
    var value = ""
    /// A value the daemon already holds. It arrives blank and stays blank unless something is
    /// typed over it, which is exactly what keeps it.
    var stored = false
}

/// The keys a server carries, blank, because blank is what keeps a stored value.
private func storedRows(of server: McpServerSummary?) -> [SecretRow] {
    (server?.secretKeys ?? []).map { SecretRow(key: $0, stored: true) }
}

/// Adding or changing one server. Every key the form holds goes out on every save — a key the
/// body leaves out is removed with it — and a stored value goes out blank, which keeps it.
private struct ServerSheet: View {
    let session: Session
    /// Nil when adding. An existing server's name is not editable: the name is the route's path,
    /// so a changed one would store a second server rather than rename the one on screen.
    let existing: McpServerSummary?
    let onSaved: ([McpServerSummary]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var draft: McpServerDraft
    /// One argument per line, so an argument may contain spaces. A blank line is not an argument.
    @State private var args: String
    @State private var secrets: [SecretRow]
    @State private var pasted = ""
    @State private var trouble: String?
    @State private var saving = false

    init(session: Session, existing: McpServerSummary?, onSaved: @escaping ([McpServerSummary]) -> Void) {
        self.session = session
        self.existing = existing
        self.onSaved = onSaved
        _draft = State(initialValue: existing.map {
            McpServerDraft(
                name: $0.name,
                transport: $0.transport,
                command: $0.command ?? "",
                url: $0.url ?? ""
            )
        } ?? McpServerDraft())
        _args = State(initialValue: (existing?.args ?? []).joined(separator: "\n"))
        _secrets = State(initialValue: storedRows(of: existing))
    }

    private var block: String { draft.transport == .stdio ? "Environment" : "Headers" }
    private var one: String { draft.transport == .stdio ? "variable" : "header" }

    /// The form as the route wants it. Blank argument lines and nameless secret rows are dropped;
    /// a blank value is not, because that is how a stored one is kept.
    private var wanted: McpServerDraft {
        var built = draft
        built.name = draft.name.trimmingCharacters(in: .whitespaces)
        built.args = args.split(whereSeparator: \.isNewline).map(String.init)
        built.secrets = secrets.compactMap { row in
            let key = row.key.trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : McpServerDraft.Secret(key: key, value: row.value)
        }
        return built
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("Name", text: $draft.name, prompt: Text(verbatim: "files"))
                            .rowField()
                            .disabled(existing != nil)
                    }
                    // Which block the daemon fills from what it holds follows the *stored*
                    // transport, so secrets do not travel across a switch; coming back to it
                    // finds them again. Cleared here rather than on a change of the transport
                    // itself, which a filled-in snippet also changes and whose rows must stay.
                    Picker("Transport", selection: Binding(get: { draft.transport }, set: { picked in
                        draft.transport = picked
                        secrets = picked == existing?.transport ? storedRows(of: existing) : []
                    })) {
                        Text(verbatim: "stdio").tag(McpServerSummary.Transport.stdio)
                        Text(verbatim: "http").tag(McpServerSummary.Transport.http)
                    }
                    .pickerStyle(.menu)

                    if draft.transport == .stdio {
                        LabeledContent("Command") {
                            TextField("Command", text: $draft.command, prompt: Text(verbatim: "npx"))
                                .rowField()
                        }
                        TextField("Arguments", text: $args, prompt: Text("One per line"), axis: .vertical)
                            .font(.callout.monospaced())
                            .lineLimit(1...6)
                    } else {
                        LabeledContent("URL") {
                            TextField("URL", text: $draft.url, prompt: Text(verbatim: "https://mcp.example.com/mcp"))
                                #if os(iOS)
                                .keyboardType(.URL)
                                #endif
                                .rowField()
                        }
                    }
                } footer: {
                    Text(existing == nil
                        ? "The name is how the daemon addresses the server and how its tools are spelled, and it cannot be changed afterwards."
                        : "A server is renamed by adding it again under the new name and deleting this one.")
                }

                Section {
                    ForEach($secrets) { $row in
                        HStack {
                            TextField("Name", text: $row.key, prompt: Text("Name"))
                                .font(.callout.monospaced())
                                .rowField()
                            SecureField(
                                "Value",
                                text: $row.value,
                                prompt: Text(row.stored ? "Stored" : "Value")
                            )
                            .rowField()
                            Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                secrets.removeAll { $0.id == row.id }
                            }
                            .buttonStyle(.borderless)
                            .labelStyle(.iconOnly)
                        }
                    }
                    Button("Add \(one)", systemImage: "plus") {
                        secrets.append(SecretRow())
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text(block)
                } footer: {
                    Text("Never read back. One shown as Stored keeps its value unless something is typed over it; removing the row removes it from the server.")
                }

                if existing == nil {
                    Section {
                        TextField(
                            "Snippet",
                            text: $pasted,
                            prompt: Text(verbatim: #"{"mcpServers": {"files": {…}}}"#),
                            axis: .vertical
                        )
                        .font(.callout.monospaced())
                        .lineLimit(2...8)
                        .rowField()
                        Button("Fill from snippet", action: fill)
                            .buttonStyle(.borderless)
                            .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } header: {
                        Text("Paste")
                    } footer: {
                        Text("A block out of an MCP README, or one entry of the daemon's own array. It fills the form above; nothing is written until Save.")
                    }
                }

                if let trouble {
                    Section {
                        Text(trouble)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .navigationTitle(existing?.name ?? "Add server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save", action: save)
                        .disabled(saving)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    private func fill() {
        do {
            let one = try mcpServer(fromDraft: pasted)
            draft = one
            args = one.args.joined(separator: "\n")
            secrets = one.secrets.map { SecretRow(key: $0.key, value: $0.value) }
            pasted = ""
            trouble = nil
        } catch {
            trouble = error.localizedDescription
        }
    }

    /// The name is refused here rather than by the daemon: it is the route's path, so an empty
    /// one asks a different URL. Everything else — the charset, the url's scheme, how many
    /// servers there may be — stays the daemon's to judge.
    private func save() {
        let server = wanted
        guard !saving else { return }
        guard !server.name.isEmpty else {
            trouble = "A server needs a name."
            return
        }
        saving = true
        trouble = nil
        Task {
            do {
                onSaved(try await session.run { try await $0.putMcpServer(server) })
                dismiss()
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            saving = false
        }
    }
}

private struct ServerRow: View {
    let server: McpServerSummary
    let result: McpTestResult?
    let testing: Bool
    let canTest: Bool
    let onTest: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(server.name).font(.headline).lineLimit(1)
                Text(server.transport.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                // Borderless on every one of them: two plain buttons in one iOS Form row fire
                // together.
                Button(testing ? "Testing…" : "Test", action: onTest)
                    .disabled(testing || !canTest)
                Button("Edit", action: onEdit)
                Button("Delete", role: .destructive, action: onDelete)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Text(server.detail)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if !server.secretKeys.isEmpty {
                Text("Carries " + server.secretKeys.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let result {
                Label(result.report, systemImage: result.ok ? "checkmark.circle" : "xmark.octagon")
                    .font(.footnote)
                    .foregroundStyle(result.ok ? Color.secondary : Color.red)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

extension McpServerSummary {
    /// The endpoint, or the command line rebuilt: the daemon sends a stdio server's executable
    /// and its arguments apart so a screen can edit them one at a time.
    var detail: String {
        url ?? ([command].compactMap { $0 } + (args ?? [])).joined(separator: " ")
    }
}

extension McpTestResult {
    /// What a connection test came back with, as one line.
    var report: String {
        guard ok else { return error ?? "Could not be reached" }
        guard !tools.isEmpty else { return "Connected, no tools offered" }
        return "\(tools.count) tool\(tools.count == 1 ? "" : "s"): " + tools.joined(separator: ", ")
    }
}
