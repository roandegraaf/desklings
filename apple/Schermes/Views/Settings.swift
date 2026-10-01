import SwiftUI

/// The daemon's configuration, one page per category. Each page with fields loads the whole
/// settings object and saves only the fields it owns: `PUT /api/settings` keeps every field a
/// body leaves out.
enum SettingsCategory: String, CaseIterable, Identifiable {
    /// The Mac settings sheet's last tab.
    static let storageKey = "schermes.settingsTab"

    case model
    case web
    case notifications
    case plugins
    case daemon
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .model: "Models"
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

    /// The tile behind the symbol on the iOS list, as the Settings app colours its rows.
    var tint: BloubColorId {
        switch self {
        case .model: BloubColorId.violet
        case .web: BloubColorId.blue
        case .notifications: BloubColorId.red
        case .plugins: BloubColorId.orange
        case .daemon: BloubColorId.grey
        case .about: BloubColorId.teal
        }
    }
}

/// A page carries no navigation of its own: on iOS it is pushed onto the sheet's stack, on the Mac
/// it sits bare under the sheet's tab strip.
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

struct SettingsRequest: Identifiable {
    let id = UUID()
    var start: SettingsCategory?

    #if os(macOS)
    /// Set by ⌘, until a console takes it: with the console window closed nobody hears the
    /// notification, so the console that opens next presents the sheet.
    static var pending = false

    /// ⌘,: the sheet belongs to the console window, so that window is brought back or opened first.
    static func ask(consoleWindow: NSWindow?, openConsole: () -> Void) {
        pending = true
        if let consoleWindow {
            consoleWindow.makeKeyAndOrderFront(nil)
        } else {
            openConsole()
        }
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }
    #endif
}

#if os(macOS)
/// A hidden or minimised console counts: `openWindow` on a `WindowGroup` always makes another one.
var consoleWindow: NSWindow? {
    NSApp.windows.first {
        $0.identifier?.rawValue.hasPrefix(consoleWindowID) == true && ($0.isVisible || $0.isMiniaturized)
    }
}

struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            SettingsRequest.ask(consoleWindow: consoleWindow) { openWindow(id: consoleWindowID) }
        }
        .keyboardShortcut(",")
    }
}
#endif

extension View {
    /// The app settings sheet. On the Mac the app menu's Settings… (⌘,) opens it too, through
    /// `.showSettings` or, for a console that was closed, `SettingsRequest.pending`.
    func settingsSheet<Content: View>(
        _ request: Binding<SettingsRequest?>, @ViewBuilder content: @escaping (SettingsRequest) -> Content
    ) -> some View {
        sheet(item: request, content: content)
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
                SettingsRequest.pending = false
                if request.wrappedValue == nil { request.wrappedValue = SettingsRequest() }
            }
            .onAppear {
                guard SettingsRequest.pending else { return }
                SettingsRequest.pending = false
                if request.wrappedValue == nil { request.wrappedValue = SettingsRequest() }
            }
            #endif
    }
}

#if os(iOS)
/// The sidebar's gear opens this sheet and each row pushes its page.
struct SettingsSheet: View {
    let session: Session
    /// The page to open on, for a Needs you item that is fixed there.
    var start: SettingsCategory? = nil

    @State private var path: [SettingsCategory] = []

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack(path: $path) {
            List(SettingsCategory.allCases) { category in
                NavigationLink(value: category) {
                    Label {
                        Text(category.title)
                    } icon: {
                        Image(systemName: category.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AgentPalette(category.tint, dark: scheme == .dark).softText.color)
                            .frame(width: 30, height: 30)
                            .background(AgentPalette(category.tint, dark: scheme == .dark).soft.color, in: .rect(cornerRadius: 9))
                    }
                }
                .listRowBackground(Rectangle().fill(Theme.card))
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .navigationDestination(for: SettingsCategory.self) { category in
                settingsPage(category, session: session)
            }
            .navigationTitle("Settings")
            .presentationBackground(Theme.ground)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if let start, path.isEmpty { path = [start] } }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
            }
        }
    }
}
#else
/// The sidebar's gear and ⌘, open this over the console window: a tab strip, the page, Done.
struct SettingsSheet: View {
    let session: Session
    /// The page to open on, for a Needs you item that is fixed there.
    var start: SettingsCategory? = nil

    @AppStorage(SettingsCategory.storageKey) private var tab: SettingsCategory = .model

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Settings") {
                Button("Done") { dismiss() }
                    .buttonStyle(.pill(.primary))
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            tabs
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            settingsPage(tab, session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.ground)
        .frame(minWidth: 700, minHeight: 480, idealHeight: 580)
        .onAppear { if let start { tab = start } }
    }

    /// The Rules page's quiet track, the picked tab filled in ink.
    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(SettingsCategory.allCases) { category in
                let picked = tab == category
                Button { tab = category } label: {
                    Label(category.title, systemImage: category.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .foregroundStyle(picked ? AnyShapeStyle(Theme.onInk) : AnyShapeStyle(Theme.secondary))
                        .background(picked ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
                        .contentShape(.rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.ink.opacity(0.05), in: .rect(cornerRadius: 14))
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
                ThemedForm {
                    fields(form, stored, unchanged)

                    Section {
                        Button(saving ? "Saving…" : "Save", action: save)
                            .buttonStyle(.pill(.primary))
                            .disabled(saving || unchanged)
                        if let trouble {
                            Text(trouble)
                                .font(.footnote)
                                .foregroundStyle(Theme.failed)
                        } else if saved && unchanged {
                            Text("Saved.")
                                .font(.footnote)
                                .foregroundStyle(Theme.muted)
                        }
                    } footer: {
                        Text(footer)
                    }
                }
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

/// What the models sheet edits.
struct ModelDraft: Equatable {
    var name = ""
    var providerId: Int?
    var model = ""
    var extraBody = ""

    init(providerId: Int? = nil) {
        self.providerId = providerId
    }

    init(_ entry: ModelEntry) {
        name = entry.name
        providerId = entry.providerId
        model = entry.model
        extraBody = entry.extraBody
    }

    /// Everything for a new entry, only what changed for an existing one.
    func update(from existing: ModelEntry?) -> ModelUpdate {
        let name = name.trimmingCharacters(in: .whitespaces)
        let model = model.trimmingCharacters(in: .whitespaces)
        let extraBody = typedJSON(extraBody)
        return ModelUpdate(
            name: name == existing?.name ? nil : name,
            providerId: providerId == existing?.providerId ? nil : providerId,
            model: model == existing?.model ? nil : model,
            extraBody: extraBody == (existing?.extraBody ?? "") ? nil : extraBody
        )
    }
}

/// What the providers sheet edits. The key starts blank and goes out only when something is
/// typed: an empty key would remove the stored one.
struct ProviderDraft: Equatable {
    var name = ""
    var baseUrl = ""
    var apiKey = ""

    init() {}

    init(_ entry: ProviderEntry) {
        name = entry.name
        baseUrl = entry.baseUrl
    }

    func update(from existing: ProviderEntry?) -> ProviderUpdate {
        let name = name.trimmingCharacters(in: .whitespaces)
        let baseUrl = baseUrl.trimmingCharacters(in: .whitespaces)
        return ProviderUpdate(
            name: name == existing?.name ? nil : name,
            baseUrl: baseUrl == existing?.baseUrl ? nil : baseUrl,
            apiKey: apiKey.isEmpty ? nil : apiKey
        )
    }
}

/// What the models sheet is open on: an entry, or nothing for Add.
private struct ModelEdit: Identifiable {
    let id = UUID()
    var entry: ModelEntry? = nil
}

private struct ProviderEdit: Identifiable {
    let id = UUID()
    var entry: ProviderEntry? = nil
}

/// The model registry: any number of endpoints, one default for agents with none of their own and
/// an optional backup. The list is fetched again after every change, because the daemon moves the
/// badges itself (the first entry becomes the default, deleting the backup clears it).
private struct ModelPage: View {
    let session: Session

    @State private var models: [ModelEntry]?
    @State private var providers: [ProviderEntry]?
    @State private var results: [Int: ProviderTestResult] = [:]
    @State private var testing: Set<Int> = []
    @State private var editing: ModelEdit?
    @State private var editingProvider: ProviderEdit?
    @State private var removing: ModelEntry?
    @State private var removingProvider: ProviderEntry?
    @State private var trouble: String?

    var body: some View {
        ThemedForm {
            Section {
                if let providers {
                    ForEach(providers) { provider in
                        ProviderRow(
                            provider: provider,
                            onEdit: { editingProvider = ProviderEdit(entry: provider) },
                            onDelete: { removingProvider = provider }
                        )
                        #if os(iOS)
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { removingProvider = provider }
                        }
                        #endif
                    }
                }

                Button("Add provider", systemImage: "plus") { editingProvider = ProviderEdit() }
                    .buttonStyle(.pill(.secondary))
                    .disabled(providers == nil)
            } header: {
                Text("Providers").formHeader()
            } footer: {
                Text("An endpoint and its key, shared by every model you add on it.")
            }
            .sheet(item: $editingProvider) { edit in
                ProviderSheet(session: session, existing: edit.entry) {
                    results = [:]
                    Task { await load() }
                }
            }
            .confirmationDialog(
                removingProvider.map { "Delete \($0.name)?" } ?? "",
                isPresented: Binding(get: { removingProvider != nil }, set: { if !$0 { removingProvider = nil } }),
                titleVisibility: .visible,
                presenting: removingProvider
            ) { provider in
                Button("Delete", role: .destructive) {
                    change { try await $0.deleteProvider(id: provider.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its endpoint and key are deleted with it.")
            }

            Section {
                if let models {
                    if models.isEmpty {
                        Text(providers?.isEmpty == false
                            ? "No models yet. Agents cannot think until one is added."
                            : "Add a provider first, then the models it serves.")
                            .foregroundStyle(Theme.muted)
                    }
                    ForEach(models) { entry in
                        ModelRow(
                            entry: entry,
                            result: results[entry.id],
                            testing: testing.contains(entry.id),
                            onTest: { test(entry) },
                            onEdit: { editing = ModelEdit(entry: entry) },
                            onDefault: { change { try await $0.setDefaultModel(id: entry.id) } },
                            onBackup: { pick in change { try await $0.setBackupModel(id: pick) } },
                            onDelete: { removing = entry }
                        )
                        #if os(iOS)
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { removing = entry }
                        }
                        #endif
                    }
                } else if trouble == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }

                Button("Add model", systemImage: "plus") { editing = ModelEdit() }
                    .buttonStyle(.pill(.secondary))
                    .disabled(models == nil || providers?.isEmpty != false)

                if let trouble {
                    Text(trouble)
                        .font(.footnote)
                        .foregroundStyle(Theme.failed)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Models").formHeader()
            } footer: {
                Text("OpenAI-compatible endpoints with tool calling and vision. An agent runs on its own model when it has one, else on the default. The backup stands in when the default is rate-limited or down.")
            }
        }
        .navigationTitle(SettingsCategory.model.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .sheet(item: $editing) { edit in
            ModelSheet(session: session, existing: edit.entry, providers: providers ?? []) {
                results = [:]
                Task { await load() }
            }
        }
        .confirmationDialog(
            removing.map { "Delete \($0.name)?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { entry in
            Button("Delete", role: .destructive) {
                results[entry.id] = nil
                change { try await $0.deleteModel(id: entry.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its provider and key stay.")
        }
    }

    private func load() async {
        do {
            async let fetchedProviders = session.run { try await $0.providers() }
            async let fetchedModels = session.run { try await $0.models() }
            (providers, models) = try await (fetchedProviders, fetchedModels)
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }

    /// The daemon's refusal (a model still assigned, a default with others left) is shown as it
    /// came, under the list.
    private func change<T: Sendable>(_ call: @escaping @Sendable (SchermesClient) async throws -> T) {
        trouble = nil
        Task {
            do {
                _ = try await session.run(call)
                await load()
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
        }
    }

    private func test(_ entry: ModelEntry) {
        testing.insert(entry.id)
        results[entry.id] = nil
        Task {
            do {
                results[entry.id] = try await session.run { try await $0.testModel(id: entry.id) }
            } catch {
                if !error.isCancellation {
                    results[entry.id] = ProviderTestResult(ok: false, reply: nil, error: error.localizedDescription)
                }
            }
            testing.remove(entry.id)
        }
    }
}

/// The Mac draws it in a round pill, so the circle would be drawn twice.
#if os(macOS)
private let moreSymbol = "ellipsis"
#else
private let moreSymbol = "ellipsis.circle"
#endif

private struct ModelRow: View {
    let entry: ModelEntry
    let result: ProviderTestResult?
    let testing: Bool
    let onTest: () -> Void
    let onEdit: () -> Void
    let onDefault: () -> Void
    let onBackup: (Int?) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.name).font(.headline).lineLimit(1)
                if entry.isDefault { ModelBadge(word: "Default", symbol: "star.fill") }
                if entry.isBackup { ModelBadge(word: "Backup", symbol: "arrow.triangle.2.circlepath") }
                Spacer(minLength: 8)
                // A style on every one of them: two plain buttons in one iOS Form row fire together.
                Button(testing ? "Testing…" : "Test", action: onTest)
                    .buttonStyle(.pill(.secondary))
                    .disabled(testing || !entry.apiKeySet)
                Menu("More", systemImage: moreSymbol) {
                    Button("Edit…", systemImage: "pencil", action: onEdit)
                    if !entry.isDefault {
                        Button("Make default", systemImage: "star", action: onDefault)
                    }
                    if entry.isBackup {
                        Button("No backup", systemImage: "xmark.circle") { onBackup(nil) }
                    } else if !entry.isDefault {
                        Button("Use as backup", systemImage: "arrow.triangle.2.circlepath") { onBackup(entry.id) }
                    }
                    Divider()
                    Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
                #if os(macOS)
                .menuStyle(.button)
                .buttonStyle(.pill(.secondary, round: true))
                #endif
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Text(entry.model)
                .font(.caption.monospaced())
                .lineLimit(1)
            Text((entry.providerName ?? entry.baseUrl) + (entry.apiKeySet ? "" : " · no key"))
                .font(.caption.monospaced())
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            if let result {
                Label(
                    result.ok
                        ? ((result.reply ?? "").isEmpty ? "Answered" : "Answered: \(result.reply ?? "")")
                        : (result.error ?? "Could not be reached"),
                    systemImage: result.ok ? "checkmark.circle" : "xmark.octagon"
                )
                .font(.footnote)
                .foregroundStyle(result.ok ? AnyShapeStyle(Theme.muted) : AnyShapeStyle(Theme.failed))
                .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ProviderRow: View {
    let provider: ProviderEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.name).font(.headline).lineLimit(1)
                Text(provider.baseUrl + (provider.apiKeySet ? "" : " · no key"))
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu("More", systemImage: moreSymbol) {
                Button("Edit…", systemImage: "pencil", action: onEdit)
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
            }
            .labelStyle(.iconOnly)
            .menuIndicator(.hidden)
            #if os(macOS)
            .menuStyle(.button)
            .buttonStyle(.pill(.secondary, round: true))
            #endif
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.vertical, 2)
    }
}

/// Adding or changing one provider. The key is write-only: a stored one shows as set, never as
/// itself, and a blank field keeps it.
private struct ProviderSheet: View {
    let session: Session
    let existing: ProviderEntry?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var draft: ProviderDraft
    @State private var trouble: String?
    @State private var saving = false

    init(session: Session, existing: ProviderEntry?, onSaved: @escaping () -> Void) {
        self.session = session
        self.existing = existing
        self.onSaved = onSaved
        _draft = State(initialValue: existing.map(ProviderDraft.init) ?? ProviderDraft())
    }

    var body: some View {
        ThemedForm {
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: $draft.name, prompt: Text("OpenAI, OpenRouter, Local…"))
                        .rowField()
                }
                LabeledContent("Base URL") {
                    TextField("Base URL", text: $draft.baseUrl, prompt: Text(verbatim: "https://api.example.com/v1"))
                        #if os(iOS)
                        .keyboardType(.URL)
                        #endif
                        .rowField()
                }
                LabeledContent("API key") {
                    SecureField("API key", text: $draft.apiKey, prompt: Text(existing?.apiKeySet == true ? "Set" : "Not set"))
                        .rowField()
                }
            } footer: {
                Text("The key is encrypted on the daemon and never comes back out. Leave it blank to keep the one stored. Every model on this provider uses it.")
            }

            if let trouble {
                Section {
                    Text(trouble)
                        .font(.footnote)
                        .foregroundStyle(Theme.failed)
                        .textSelection(.enabled)
                }
            }
        }
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
        .sheetChrome(
            existing?.name ?? "Add provider",
            confirm: saving ? "Saving…" : "Save",
            confirmDisabled: saving,
            cancel: { dismiss() },
            onConfirm: save
        )
        .presentationBackground(Theme.ground)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 280)
        #endif
    }

    private func save() {
        guard !saving else { return }
        let update = draft.update(from: existing)
        guard existing == nil || update != ProviderUpdate() else {
            dismiss()
            return
        }
        saving = true
        trouble = nil
        Task {
            do {
                if let existing {
                    _ = try await session.run { try await $0.updateProvider(id: existing.id, update) }
                } else {
                    _ = try await session.run { try await $0.createProvider(update) }
                }
                onSaved()
                dismiss()
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            saving = false
        }
    }
}

private struct ModelBadge: View {
    let word: String
    let symbol: String

    var body: some View {
        Label(word, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
    }
}

/// Adding or changing one model on one of the providers.
private struct ModelSheet: View {
    let session: Session
    let existing: ModelEntry?
    let providers: [ProviderEntry]
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var draft: ModelDraft
    @State private var trouble: String?
    @State private var saving = false

    init(session: Session, existing: ModelEntry?, providers: [ProviderEntry], onSaved: @escaping () -> Void) {
        self.session = session
        self.existing = existing
        self.providers = providers
        self.onSaved = onSaved
        _draft = State(initialValue: existing.map(ModelDraft.init) ?? ModelDraft(providerId: providers.first?.id))
    }

    var body: some View {
        ThemedForm {
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: $draft.name, prompt: Text("Fast, Smart, Local…"))
                        .rowField()
                }
                Picker("Provider", selection: $draft.providerId) {
                    if draft.providerId == nil {
                        Text("None").tag(Int?.none)
                    }
                    ForEach(providers) { provider in
                        Text(provider.name).tag(Optional(provider.id))
                    }
                }
                LabeledContent("Model") {
                    TextField("Model", text: $draft.model, prompt: Text(verbatim: "gpt-5"))
                        .font(.body.monospaced())
                        .rowField()
                }
            } footer: {
                Text("The provider holds the endpoint and the key.")
            }

            Section {
                TextField(
                    "Extra request fields",
                    text: $draft.extraBody,
                    prompt: Text(verbatim: #"{"reasoning":{"effort":"high"}}"#),
                    axis: .vertical
                )
                .font(.callout.monospaced())
                .lineLimit(1...6)
                .rowField()
            } header: {
                Text("Extra request fields").formHeader()
            } footer: {
                Text("A JSON object merged into every request to this model: routing, reasoning effort, token caps. Empty for none.")
            }

            if let trouble {
                Section {
                    Text(trouble)
                        .font(.footnote)
                        .foregroundStyle(Theme.failed)
                        .textSelection(.enabled)
                }
            }
        }
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
        .sheetChrome(
            existing?.name ?? "Add model",
            confirm: saving ? "Saving…" : "Save",
            confirmDisabled: saving,
            cancel: { dismiss() },
            onConfirm: save
        )
        .presentationBackground(Theme.ground)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 440)
        #endif
    }

    /// Checking the fields is the daemon's: its refusal is shown as it came and the sheet keeps
    /// what was typed.
    private func save() {
        guard !saving else { return }
        let update = draft.update(from: existing)
        guard existing == nil || update != ModelUpdate() else {
            dismiss()
            return
        }
        saving = true
        trouble = nil
        Task {
            do {
                if let existing {
                    _ = try await session.run { try await $0.updateModel(id: existing.id, update) }
                } else {
                    _ = try await session.run { try await $0.createModel(update) }
                }
                onSaved()
                dismiss()
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            saving = false
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
                    .buttonStyle(.pill(.secondary))
                    .disabled(pushing || !unchanged || !stored.push.keySet || devices.isEmpty)
                if let pushed {
                    Label(
                        pushed.ok ? "Sent to \(pushed.sent) device\(pushed.sent == 1 ? "" : "s")" : (pushed.error ?? "Could not send"),
                        systemImage: pushed.ok ? "checkmark.circle" : "xmark.octagon"
                    )
                    .font(.footnote)
                    .foregroundStyle(pushed.ok ? AnyShapeStyle(Theme.muted) : AnyShapeStyle(Theme.failed))
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
                Text(stored.push.keySet ? "Key" : "Key (not set)").formHeader()
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
        ThemedForm {
            Section {
                LabeledContent("Address", value: session.client?.baseURL.absoluteString ?? "none")
                    .textSelection(.enabled)
                // The address only: the password stays in the Keychain under it, so coming back
                // to this daemon does not ask for one again.
                Button("Use a different daemon") {
                    dismiss()
                    session.forgetServer()
                }
                .buttonStyle(.pill(.secondary))
            }

            Section {
                Button("Log out", role: .destructive) {
                    dismiss()
                    Task { await session.logOut() }
                }
                .buttonStyle(.pill(.destructive))
            } footer: {
                Text("Logging out keeps the address and the stored password; using a different daemon keeps neither.")
            }
        }
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
        ThemedForm {
            Section {
                if let servers {
                    if servers.isEmpty {
                        Text("No servers configured.").foregroundStyle(Theme.muted)
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
                    Text(trouble).foregroundStyle(Theme.failed)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }

                // A row rather than a toolbar item: on the Mac this page sits in a `Settings`
                // scene whose toolbar is already the category tabs.
                Button("Add server", systemImage: "plus") { editing = ServerEdit() }
                    .buttonStyle(.pill(.secondary))
                    .disabled(servers == nil)

                if let trouble, servers != nil {
                    Text(trouble)
                        .font(.footnote)
                        .foregroundStyle(Theme.failed)
                }
            } header: {
                Text("Configured").formHeader()
            } footer: {
                Text("Owner-wide. Every server is connected at the start of an agent's turn and its tools are offered as `mcp__<server>__<tool>`.")
            }

            Section {
                if agents.isEmpty {
                    Text("Create an agent to test a server as.").foregroundStyle(Theme.muted)
                } else {
                    ValueMenu("Test as", value: agents.first { $0.name == testAs }?.title ?? "", selection: Binding(get: { testAs }, set: { chosen = $0; results = [:] })) {
                        ForEach(agents) { Text($0.title).tag(Optional($0.name)) }
                    }
                }
            } footer: {
                Text("A stdio server is started as that agent's Linux user, so a test says what that agent would get.")
            }
        }
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
        ThemedForm {
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
                ValueMenu("Transport", value: draft.transport.rawValue, selection: Binding(get: { draft.transport }, set: { picked in
                    draft.transport = picked
                    secrets = picked == existing?.transport ? storedRows(of: existing) : []
                })) {
                    Text(verbatim: "stdio").tag(McpServerSummary.Transport.stdio)
                    Text(verbatim: "http").tag(McpServerSummary.Transport.http)
                }

                if draft.transport == .stdio {
                    LabeledContent("Command") {
                        TextField("Command", text: $draft.command, prompt: Text(verbatim: "npx"))
                            .rowField()
                    }
                    TextField("Arguments", text: $args, prompt: Text("One per line"), axis: .vertical)
                        .font(.callout.monospaced())
                        .lineLimit(1...6)
                        .formLabel("Arguments")
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
                .buttonStyle(.pill(.secondary))
            } header: {
                Text(block).formHeader()
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
                        .buttonStyle(.pill(.secondary))
                        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Paste").formHeader()
                } footer: {
                    Text("A block out of an MCP README, or one entry of the daemon's own array. It fills the form above; nothing is written until Save.")
                }
            }

            if let trouble {
                Section {
                    Text(trouble)
                        .font(.footnote)
                        .foregroundStyle(Theme.failed)
                        .textSelection(.enabled)
                }
            }
        }
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
        .sheetChrome(
            existing?.name ?? "Add server",
            confirm: saving ? "Saving…" : "Save",
            confirmDisabled: saving,
            cancel: { dismiss() },
            onConfirm: save
        )
        .presentationBackground(Theme.ground)
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
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                // A style on every one of them: two plain buttons in one iOS Form row fire together.
                Button(testing ? "Testing…" : "Test", action: onTest)
                    .buttonStyle(.pill(.secondary))
                    .disabled(testing || !canTest)
                Button("Edit", action: onEdit)
                    .buttonStyle(.pill(.secondary))
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.pill(.destructive))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Text(server.detail)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
            if !server.secretKeys.isEmpty {
                Text("Carries " + server.secretKeys.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            if let result {
                Label(result.report, systemImage: result.ok ? "checkmark.circle" : "xmark.octagon")
                    .font(.footnote)
                    .foregroundStyle(result.ok ? AnyShapeStyle(Theme.muted) : AnyShapeStyle(Theme.failed))
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
