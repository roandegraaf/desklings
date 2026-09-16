import SwiftUI

/// What an agent has been doing, newest first, as sentences rather than the raw payloads the web
/// UI prints. Polled on the desktop's 4 s tick while it is on screen, and not at all otherwise.
struct ActivityView: View {
    let session: Session
    let agent: String

    @State private var events: [ExecutionEvent]?

    /// The daemon answers with the newest this many, oldest first; the list reads newest first.
    private let tail = 200

    private var newest: [ExecutionEvent] {
        Array((events ?? []).reversed())
    }

    var body: some View {
        List(newest) { event in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol(event.type))
                    .foregroundStyle(event.type == .failure ? Color.red : Color.secondary)
                    .frame(width: 18)
                Text(sentence(for: event))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Text(shortTime(event.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .listStyle(.plain)
        .overlay {
            if events == nil {
                ProgressView()
            } else if newest.isEmpty {
                ContentUnavailableView("Nothing recorded yet", systemImage: "list.bullet.rectangle")
            }
        }
        .task(id: agent) {
            while !Task.isCancelled {
                if let rows = try? await session.run({ try await $0.events(agent: agent, limit: tail) }) {
                    events = rows
                }
                try? await Task.sleep(for: .seconds(4))
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
        }
    }
}

/// Profile, routines, activity and memory for one agent, one page at a time: in the inspector
/// column on regular width, and in a sheet from the chat's toolbar on compact.
struct AgentPages: View {
    let session: Session
    let agent: Agent

    enum Page: String, CaseIterable, Identifiable {
        case profile = "Profile"
        case routines = "Routines"
        case activity = "Activity"
        case memory = "Memory"

        var id: String { rawValue }
    }

    @State private var page: Page

    init(session: Session, agent: Agent, page: Page = .profile) {
        self.session = session
        self.agent = agent
        _page = State(initialValue: page)
    }

    var body: some View {
        // A switch rather than both kept alive: the list that is not showing must stop polling.
        Group {
            switch page {
            case .profile: ProfileView(session: session, agent: agent)
            case .routines: RoutinesView(session: session, agent: agent)
            case .activity: ActivityView(session: session, agent: agent.name)
            case .memory: MemoryView(session: session, agent: agent)
            }
        }
        // In the content rather than the toolbar: a macOS sheet has no toolbar to put a
        // `.principal` item in, and the inspector column has no toolbar of its own.
        .safeAreaInset(edge: .top) {
            Picker("Show", selection: $page) {
                ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

struct RoutinesAndActivity: View {
    let session: Session
    let agent: Agent
    var page: AgentPages.Page = .profile

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AgentPages(session: session, agent: agent, page: page)
                .navigationTitle(agent.title)
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
    }
}
