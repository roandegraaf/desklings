import SwiftUI

/// The provider the agents think with and the endpoint `web_search` asks. Both keys are
/// write-only: a stored one shows as stored, never as itself.
struct SettingsView: View {
    let session: Session

    @State private var stored: DaemonSettings?
    @State private var form: SettingsForm?
    @State private var trouble: String?
    @State private var saving = false
    @State private var saved = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                // Nothing to edit until the daemon has answered: a save sends every field.
                if let stored, let form = Binding($form) {
                    fields(form, stored)
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
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 600)
        #endif
        .task { await load() }
    }

    private func fields(_ form: Binding<SettingsForm>, _ stored: DaemonSettings) -> some View {
        let unchanged = form.wrappedValue == SettingsForm(stored)
        return Form {
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
            } header: {
                Text("Provider")
            } footer: {
                Text("One OpenAI-compatible endpoint with tool calling and vision.")
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
            } header: {
                Text("Web search")
            } footer: {
                Text("A Brave Search subscription token. Without one `web_search` refuses and says so; `web_fetch` needs no key. Set the endpoint only for a proxy or a mirror that answers in Brave's shape.")
            }

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
                Text("Keys are encrypted on the daemon and never come back out. Leave a key blank to keep the one stored.")
            }
        }
        .formStyle(.grouped)
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
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
                let answer = try await session.run { try await $0.saveSettings(form.update) }
                stored = answer
                self.form = SettingsForm(answer)
                saved = true
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            saving = false
        }
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

private let example = """
[
  {"name": "files", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]},
  {"name": "docs", "url": "https://mcp.example.com/mcp", "headers": {"Authorization": "Bearer …"}}
]
"""

/// The owner's MCP servers, which the reference calls plugins: the same JSON box the web UI uses,
/// and a connection test per server, run as one agent because a stdio server starts as that
/// agent's Linux user.
struct PluginsView: View {
    let session: Session
    /// Permanent agents only: a task worker has no Linux user of its own to test as.
    let agents: [Agent]

    @State private var servers: [McpServerSummary]?
    @State private var chosen: String?
    @State private var results: [String: McpTestResult] = [:]
    @State private var testing: Set<String> = []
    @State private var draft = ""
    @State private var trouble: String?
    @State private var saving = false
    @State private var saved = false
    @Environment(\.dismiss) private var dismiss

    private var testAs: String? { chosen ?? agents.first?.name }

    var body: some View {
        NavigationStack {
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
                                canTest: testAs != nil
                            ) { test(server.name) }
                        }
                    } else if let trouble {
                        Text(trouble).foregroundStyle(.red)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }

                    if agents.isEmpty {
                        Text("Create an agent to test a server as.").foregroundStyle(.secondary)
                    } else {
                        Picker("Test as", selection: Binding(get: { testAs }, set: { chosen = $0; results = [:] })) {
                            ForEach(agents) { Text($0.name).tag(Optional($0.name)) }
                        }
                    }
                } header: {
                    Text("Configured")
                } footer: {
                    Text("Owner-wide. Every server is connected at the start of an agent's turn and its tools are offered as `mcp__<server>__<tool>`.")
                }

                Section {
                    TextEditor(text: $draft)
                        .font(.callout.monospaced())
                        .frame(minHeight: 150)
                    Button(saving ? "Saving…" : "Save servers", action: save)
                        .disabled(saving)
                    if let trouble, servers != nil {
                        Text(trouble)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else if saved && draft.isEmpty {
                        Text("Saved.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Replace the list")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saving replaces every server, and the env values and headers above are never read back, so write out the whole list, secrets of the servers you keep included. That is also why this box starts empty. Saving it empty configures no servers at all.")
                        Text(verbatim: example).font(.caption.monospaced())
                    }
                }
            }
            .formStyle(.grouped)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .navigationTitle("Plugins")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
        .task { await load() }
    }

    private func load() async {
        do {
            servers = try await session.run { try await $0.mcpServers() }
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }

    /// The box is cleared once the daemon has the list, so the secrets typed into it are on no
    /// screen afterwards. A refusal leaves it as typed, to be fixed.
    private func save() {
        let parsed: JSONValue
        do {
            parsed = try mcpServers(fromDraft: draft)
        } catch {
            trouble = error.localizedDescription
            saved = false
            return
        }
        saving = true
        saved = false
        trouble = nil
        results = [:]
        Task {
            do {
                servers = try await session.run { try await $0.saveMcpServers(parsed) }
                draft = ""
                saved = true
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            saving = false
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

private struct ServerRow: View {
    let server: McpServerSummary
    let result: McpTestResult?
    let testing: Bool
    let canTest: Bool
    let onTest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(server.name).font(.headline)
                Text(server.transport.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(testing ? "Testing…" : "Test", action: onTest)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(testing || !canTest)
            }
            Text(server.url ?? server.command ?? "")
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

extension McpTestResult {
    /// What a connection test came back with, as one line.
    var report: String {
        guard ok else { return error ?? "Could not be reached" }
        guard !tools.isEmpty else { return "Connected, no tools offered" }
        return "\(tools.count) tool\(tools.count == 1 ? "" : "s"): " + tools.joined(separator: ", ")
    }
}
