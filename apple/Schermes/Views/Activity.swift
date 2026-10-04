import SwiftUI

/// What an agent has been doing, newest first, as sentences rather than the raw payloads the web
/// UI prints. Polled on the desktop's 4 s tick while it is on screen, and not at all otherwise.
struct ActivityView: View {
    let session: Session
    let agent: String

    @State private var events: [ExecutionEvent]?
    @State private var trouble: String?
    @Environment(\.pollPhase) private var pollPhase

    /// The daemon answers with the newest this many, oldest first; the list reads newest first.
    private let tail = 200

    private var newest: [ExecutionEvent] {
        Array((events ?? []).reversed())
    }

    var body: some View {
        List(newest) { event in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol(event.type))
                    .foregroundStyle(event.type == .failure ? AnyShapeStyle(Theme.failed) : AnyShapeStyle(Theme.muted))
                    .frame(width: 18)
                Text(sentence(for: event))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Text(shortTime(event.createdAt))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        #if os(macOS)
        .padding(.horizontal, 14)
        #endif
        .background(Theme.ground)
        .overlay {
            if events == nil, let trouble {
                ContentUnavailableView("Could not load the activity", systemImage: "exclamationmark.triangle", description: Text(trouble))
            } else if events == nil {
                ProgressView()
            } else if newest.isEmpty {
                ContentUnavailableView("Nothing recorded yet", systemImage: "list.bullet.rectangle")
            }
        }
        .task(id: PollKey(value: agent, phase: pollPhase)) {
            await session.poll(every: .seconds(4), pollPhase, failed: { session.note($0, in: &trouble) }) {
                events = try await session.run { try await $0.events(agent: agent, limit: tail) }
                trouble = nil
            }
        }
    }

    private func symbol(_ type: EventType) -> String {
        switch type {
        case .state: "circle.dotted"
        case .tool_call: "wrench.adjustable"
        case .tool_result: "arrow.turn.down.left"
        case .failure: "exclamationmark.triangle"
        case .restart: "arrow.clockwise"
        case .control: "hand.raised"
        case .schedule_dropped: "calendar.badge.minus"
        case .approval: "checkmark.seal"
        case .stop: "stop.circle"
        case .turn: "flag.checkered"
        case .unknown: "questionmark.circle"
        }
    }
}

/// Profile, routines, activity and memory for one agent: an overview that names them, and one
/// page at a time over it, so a narrow column carries a list rather than four forms behind a
/// segmented control. Only the page on screen exists, so only it polls. Its own state rather
/// than a `NavigationStack`: inside an inspector column a push landed on the detail column's
/// stack and took the chat with it.
struct AgentPages: View {
    let session: Session
    let agent: Agent
    /// Drawn above the pages on the overview: the inspector puts the agent's screen here.
    var header: AnyView? = nil
    @State private var page: Page?

    enum Page: String, CaseIterable, Identifiable {
        case profile = "Profile"
        case rules = "Rules"
        case idle = "When idle"
        case routines = "Routines and triggers"
        case activity = "Activity"
        case memory = "Memory"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .profile: "person.text.rectangle"
            case .rules: "checkmark.shield"
            case .idle: "moon.zzz"
            case .routines: "bolt.badge.clock"
            case .activity: "list.bullet.rectangle"
            case .memory: "book.closed"
            }
        }

        var detail: String {
            switch self {
            case .profile: "What it is for"
            case .rules: "What it may do on its own"
            case .idle: "What it does while you're away"
            case .routines: "Standing jobs, and what wakes it"
            case .activity: "What it has been doing"
            case .memory: "What it carries between turns"
            }
        }
    }

    /// The Mac sheet's Done: the page row becomes the sheet's header, so there is one strip.
    var done: (() -> Void)? = nil

    init(session: Session, agent: Agent, header: AnyView? = nil, page: Page? = nil, done: (() -> Void)? = nil) {
        self.session = session
        self.agent = agent
        self.header = header
        self.done = done
        _page = State(initialValue: page)
    }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AgentLooks.self) private var looks

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            if let done {
                SheetHeader(page?.rawValue ?? agent.title) {
                    if page != nil { overviewButton }
                } actions: {
                    Button("Done", action: done)
                        .buttonStyle(.pill(.primary))
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                }
            }
            #endif
            pages
        }
    }

    private var overviewButton: some View {
        Button("Overview", systemImage: "chevron.left") { show(nil) }
            .labelStyle(.iconOnly)
            .buttonStyle(.pill(.secondary, round: true))
            .controlSize(.small)
            .keyboardShortcut("[", modifiers: .command)
    }

    private var pages: some View {
        Group {
            if let page {
                VStack(spacing: 0) {
                    if done == nil {
                        HStack(spacing: 10) {
                            overviewButton
                            Text(page.rawValue).font(.sectionTitle)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    switch page {
                    case .profile: ProfileView(session: session, agent: agent)
                    case .rules: RulesView(session: session, agent: agent)
                    case .idle: IdleSettingsView(session: session, agent: agent)
                    case .routines: RoutinesView(session: session, agent: agent)
                    case .activity: ActivityView(session: session, agent: agent.name)
                    case .memory: MemoryView(session: session, agent: agent)
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                overview
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: page)
    }

    private func show(_ next: Page?) {
        page = next
    }

    private var overview: some View {
        let palette = looks[agent.name].palette(dark: scheme == .dark)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                VStack(alignment: .leading, spacing: 10) {
                    InspectorRow("Now") {
                        StateLine(state: agent.state, identity: looks[agent.name], font: rowTitleFont)
                    }
                    InspectorRow("Runs as") {
                        Text(agent.name)
                            .font(.callout.monospaced())
                            .foregroundStyle(Theme.muted)
                            .textSelection(.enabled)
                    }
                    if agent.parentId == nil {
                        AgentModelRow(session: session, agent: agent)
                    }
                }
                .padding(12)
                .background(Theme.card, in: .rect(cornerRadius: 14))

                VStack(spacing: 8) {
                    ForEach(Page.allCases.filter { agent.parentId == nil || ($0 != .rules && $0 != .idle) }) { page in
                        Button { show(page) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: page.symbol)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(palette.softText.color)
                                    .frame(width: 30, height: 30)
                                    .background(palette.soft.color, in: .rect(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(page.rawValue).font(rowTitleFont)
                                    Text(page.detail)
                                        .font(rowDetailFont)
                                        .foregroundStyle(Theme.muted)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.muted)
                            }
                            .padding(10)
                            .background(Theme.card, in: .rect(cornerRadius: 14))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens \(page.rawValue.lowercased())")
                    }
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(16)
        }
        .background(header == nil ? AnyShapeStyle(Theme.ground) : AnyShapeStyle(.clear))
    }
}

private struct InspectorRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(rowTitleFont).foregroundStyle(Theme.secondary).fixedSize()
            Spacer(minLength: 0)
            content
        }
    }
}

#if os(macOS)
private let rowTitleFont = Font.system(size: 13, weight: .semibold)
private let rowDetailFont = Font.system(size: 12)
#else
private let rowTitleFont = Font.subheadline.weight(.semibold)
private let rowDetailFont = Font.footnote
#endif

/// Which registry entry the agent thinks with, picked by name. Seeded from the polled agent and
/// then from the daemon's answer, so the menu does not flip back before the next poll.
struct AgentModelRow: View {
    let session: Session
    let agent: Agent
    /// Just the menu, as a bold value with a chevron: the settings page's subtitle carries it.
    var bare = false

    @State private var models: [ModelEntry] = []
    @State private var assigned: Int?
    @State private var trouble: String?

    init(session: Session, agent: Agent, bare: Bool = false) {
        self.session = session
        self.agent = agent
        self.bare = bare
        _assigned = State(initialValue: agent.modelId)
    }

    private var defaultName: String { models.first(where: \.isDefault)?.name ?? "none" }

    private var assignedName: String {
        assigned.flatMap { id in models.first { $0.id == id }?.name } ?? "Default (\(defaultName))"
    }

    private var picker: some View {
        ValueMenu("Model", value: assignedName, selection: Binding(get: { assigned }, set: assign)) {
            Text("Default (\(defaultName))").tag(Int?.none)
            ForEach(models) { entry in
                Text(entry.name).tag(Optional(entry.id))
            }
        }
        .labelsHidden()
        .disabled(models.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if bare {
                #if os(macOS)
                picker
                #endif
            } else {
                InspectorRow("Model") { picker }
            }
            if let trouble {
                Text(trouble).font(.caption).foregroundStyle(Theme.failed)
            }
        }
        .task {
            do {
                models = try await session.run { try await $0.models() }
            } catch {
                session.note(error, in: &trouble)
            }
        }
        .onChange(of: agent.modelId) { _, now in assigned = now }
    }

    private func assign(_ id: Int?) {
        let before = assigned
        assigned = id
        trouble = nil
        Task {
            do {
                assigned = try await session.run { try await $0.assignModel(agent: agent.name, id: id) }.modelId
            } catch {
                assigned = before
                if !error.isCancellation { trouble = error.localizedDescription }
            }
        }
    }
}

/// The pages as a sheet, from the chat's toolbar and commands on compact width, opened straight
/// on the page that was asked for.
struct RoutinesAndActivity: View {
    let session: Session
    let agent: Agent
    var page: AgentPages.Page = .profile

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        AgentPages(session: session, agent: agent, page: page) { dismiss() }
            .background(Theme.ground)
            .presentationBackground(Theme.ground)
            // Wide enough for the rules' segmented levels beside their names.
            .frame(minWidth: 720, minHeight: 600)
        #else
        NavigationStack {
            AgentPages(session: session, agent: agent, page: page)
                .navigationTitle(agent.title)
                .presentationBackground(Theme.ground)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", role: .confirm) { dismiss() }
                    }
                }
        }
        #endif
    }
}
