import SwiftUI

/// The agents as conversation rows — the threads they share listed under them, task workers nested
/// under the agent that spawned them — a row of large avatars above, and the thread of whichever
/// row is picked. `NavigationSplitView` is the sidebar on macOS and regular width and collapses to
/// its own screen on compact.
struct ConsoleView: View {
    let session: Session

    @State private var agents: [Agent] = []
    /// The newest message of each thread, keyed by `ThreadSource.key`.
    @State private var previews: [String: Message] = [:]
    @State private var picked: ThreadSource?
    /// Whose shared threads are loaded. One agent at a time, as the web UI does it: listing them
    /// for everybody would be another request per agent on every poll.
    @State private var expanded: String?
    @State private var conversations: [Conversation] = []
    @State private var openWorkers: Set<String> = []
    @State private var query = ""
    @State private var trouble: String?
    @State private var creating = false
    @State private var panel: Panel?
    @State private var inspecting = true
    /// What an agent has asked the owner to delete and nobody has answered yet.
    @State private var requests: [Approval] = []
    @State private var removing: Removal?
    @State private var dressing: Agent?
    @State private var managing: Agent?

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Room for a third column. Read out here rather than inside the split view, whose columns
    /// can each report their own size class.
    private var roomy: Bool { sizeClass == .regular }
    #else
    private var roomy: Bool { true }
    #endif

    /// What the owner is being asked to confirm. Deleting either is final, so neither happens on
    /// the press that asks for it.
    enum Removal: Identifiable {
        case agent(Agent)
        /// An agent's own thread is reached through the agent, so only a shared one is offered.
        case thread(Conversation)

        var id: String {
            switch self {
            case .agent(let agent): "agent:\(agent.name)"
            case .thread(let conversation): "thread:\(conversation.id)"
            }
        }

        var title: String {
            switch self {
            case .agent(let agent): "Delete \(agent.name)?"
            case .thread: "Delete this thread?"
            }
        }

        var detail: String {
            switch self {
            case .agent(let agent):
                let workers = agent.parentId == nil ? "its task workers, " : ""
                return "This takes \(workers)its threads, its routines and everything it has said, and cannot be undone. Its files on the machine stay."
            case .thread:
                return "Everything said in this thread goes. The agents in it stay as they are."
            }
        }
    }

    /// Everything the bottom of the sidebar opens, through one `.sheet(item:)` so a Debug build and
    /// a Release build carry the same modifiers.
    enum Panel: Identifiable {
        case settings
        case plugins
        case about

        var id: Self { self }
    }

    @Environment(AgentLooks.self) private var looks
    @Environment(Unread.self) private var unread
    @Environment(\.scenePhase) private var scenePhase

    private var awake: Bool { scenePhase == .active }

    /// `task(id:)` takes one value, and this loop turns on two.
    private struct Pair: Equatable {
        var expanded: String?
        var awake: Bool
        init(_ expanded: String?, _ awake: Bool) {
            self.expanded = expanded
            self.awake = awake
        }
    }

    private var trees: [AgentTree] { groupAgents(agents) }

    private var visible: [AgentTree] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return trees }
        return trees.filter { tree in
            tree.agent.name.lowercased().contains(needle)
                || preview(.agent(tree.agent.name))?.content.lowercased().contains(needle) == true
        }
    }

    private var thread: ChatThread? {
        switch picked {
        case .agent(let name):
            guard let agent = agents.first(where: { $0.name == name }) else { return nil }
            return .agent(agent)
        case .conversation(let id):
            guard let conversation = conversations.first(where: { $0.id == id }) else { return nil }
            return .group(
                id: conversation.id,
                members: agents.filter { conversation.participants.contains($0.name) }
            )
        case nil:
            return nil
        }
    }

    var body: some View {
        NavigationSplitView {
            list
        } detail: {
            Group {
                if let thread {
                    // Mounted fresh per thread, as the web UI keys its Chat by source: without this
                    // SwiftUI keeps one view across a switch and a half-typed draft goes to whichever
                    // thread the sidebar lands on next. A group thread carries the name of one of its
                    // members, so the source rather than the name is what has to be the identity.
                    ChatView(session: session, thread: thread, inspector: roomy ? $inspecting : nil)
                        .id(thread.source)
                } else {
                    ContentUnavailableView(
                        "No thread picked",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Pick an agent, or create one.")
                    )
                }
            }
            // Compact width would turn an inspector into a sheet, so there it never opens and the
            // chat keeps its own buttons for the screen and the routines.
            .inspector(isPresented: roomy ? $inspecting : .constant(false)) {
                // Built only while shown. SwiftUI keeps an inspector's content alive when it is not
                // presented — on a compact iPhone it held a second socket to the agent's desktop —
                // and this content holds one.
                if roomy && inspecting { inspector }
            }
        }
        // Keyed by the scene phase, so a window nobody is looking at stops asking. On iOS the
        // process is suspended anyway; on a Mac this loop is a request per agent every two
        // seconds for as long as the app is open, whether or not it is in front.
        .task(id: awake) {
            guard awake else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // Its own, slower loop: shared threads are made by agents writing to each other, which is
        // far rarer than a message arriving, and this one costs a request per thread it finds.
        .task(id: Pair(expanded, awake)) {
            conversations = []
            guard awake, expanded != nil else { return }
            while !Task.isCancelled {
                await refreshConversations()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: picked) { _, next in
            if case .agent(let name) = next { expanded = subtreeOwner(name) }
        }
        .sheet(isPresented: $creating) {
            NewAgentSheet(session: session) { agent in
                picked = .agent(agent.name)
                Task { await refresh() }
            }
        }
    }

    private var list: some View {
        List(selection: $picked) {
            ForEach(visible) { tree in
                NavigationLink(value: ThreadSource.agent(tree.agent.name)) {
                    AgentRow(
                        agent: tree.agent,
                        preview: preview(.agent(tree.agent.name)),
                        unread: isUnread(.agent(tree.agent.name))
                    )
                }
                .contextMenu { menu(for: tree.agent) }

                if expanded == tree.agent.name {
                    ForEach(sharedConversations(conversations, tree.agent.name)) { conversation in
                        NavigationLink(value: ThreadSource.conversation(conversation.id)) {
                            GroupRow(
                                conversation: conversation,
                                besides: tree.agent.name,
                                preview: preview(.conversation(conversation.id)),
                                unread: isUnread(.conversation(conversation.id))
                            )
                        }
                        .contextMenu {
                            Button("Delete thread", systemImage: "trash", role: .destructive) {
                                removing = .thread(conversation)
                            }
                        }
                    }
                }

                if !tree.workers.isEmpty {
                    WorkersToggle(count: tree.workers.count, open: openWorkers.contains(tree.agent.name)) {
                        if openWorkers.contains(tree.agent.name) {
                            openWorkers.remove(tree.agent.name)
                        } else {
                            openWorkers.insert(tree.agent.name)
                        }
                    }

                    if openWorkers.contains(tree.agent.name) {
                        // By name, for the reason `AgentTree.id` gives: a worker row and a thread
                        // row are siblings here, and their `Int` ids come from different sequences.
                        ForEach(tree.workers, id: \.name) { worker in
                            NavigationLink(value: ThreadSource.agent(worker.name)) {
                                WorkerRow(agent: worker)
                            }
                            .contextMenu {
                                Button("Delete worker", systemImage: "trash", role: .destructive) {
                                    removing = .agent(worker)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Agents")
        // A large title scrolls under the top inset, so it reads as a smudge behind the pinned
        // row's material rather than as a title.
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $query, placement: .sidebar, prompt: "Search agents")
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                pending
                pinned
            }
        }
        .overlay {
            if trees.isEmpty {
                ContentUnavailableView(
                    "No agents yet",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text(trouble ?? "Create one to start talking.")
                )
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("New agent", systemImage: "plus") { creating = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        // The sidebar's toolbar is only as wide as the sidebar, so a second button there ends up
        // behind an overflow chevron. Plugins, Log out and the settings gear live under the list.
        // The chat's pill is centred in the window and must clear this column, so with the
        // inspector open a Mac window can shrink only to about twice this width plus 320. At 240
        // that is just under 800.
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 420)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Button { panel = .plugins } label: {
                    HStack {
                        Label("Plugins", systemImage: "puzzlepiece.extension")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                Divider()

                HStack(spacing: 18) {
                    Button("Log out", systemImage: "rectangle.portrait.and.arrow.right") {
                        Task { await session.logOut() }
                    }
                    Button("About", systemImage: "info.circle") { panel = .about }
                    Spacer()
                    Button("Settings", systemImage: "gearshape") { panel = .settings }
                        .labelStyle(.iconOnly)
                        .font(.body)
                        .keyboardShortcut(",", modifiers: .command)
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(.bar)
        }
        .sheet(item: $dressing) { agent in
            AgentLookSheet(name: agent.name, state: agent.state, identity: looks[agent.name])
        }
        .sheet(item: $managing) { agent in
            RoutinesAndActivity(session: session, agent: agent)
        }
        .confirmationDialog(
            removing?.title ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { what in
            Button("Delete", role: .destructive) { remove(what) }
            Button("Cancel", role: .cancel) {}
        } message: { what in
            Text(what.detail)
        }
        .sheet(item: $panel) { shown in
            switch shown {
            case .settings:
                SettingsView(session: session)
            case .plugins:
                PluginsView(session: session, agents: agents.filter { $0.parentId == nil })
            case .about:
                AboutView(session: session)
            }
        }
    }

    /// The picked agent's screen and routines. A shared thread has several agents and a task worker
    /// has no desktop, so neither has anything to show here.
    private var inspector: some View {
        Group {
            if let agent = thread?.only, agent.parentId == nil {
                AgentInspector(session: session, agent: agent)
                    .id(agent.name)
            } else {
                ContentUnavailableView(
                    "No screen",
                    systemImage: "display",
                    description: Text("An agent's screen and routines show here. Shared threads and task workers have neither.")
                )
            }
        }
        .inspectorColumnWidth(min: 220, ideal: 250, max: 420)
    }

    /// The permanent agents as large avatars above the list. Every one of them: the row is a way
    /// to reach an agent at a glance, not a set the owner has to curate.
    @ViewBuilder private var pinned: some View {
        if !trees.isEmpty {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(trees) { tree in
                        Button { picked = .agent(tree.agent.name) } label: {
                            VStack(spacing: 6) {
                                BloubView(
                                    state: tree.agent.state.bloub,
                                    identity: looks[tree.agent.name],
                                    size: 58
                                )
                                Text(tree.agent.name)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .foregroundStyle(picked == .agent(tree.agent.name) ? .primary : .secondary)
                            }
                            .frame(width: 70)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(tree.agent.name), \(tree.agent.state.label)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .background(.bar)
        }
    }

    /// What a right-click on an agent offers: the two screens that are otherwise only reachable
    /// from inside its chat, and the one thing that cannot be undone, last and apart.
    @ViewBuilder private func menu(for agent: Agent) -> some View {
        Button("Appearance…", systemImage: "paintpalette") { dressing = agent }
        Button("Routines and activity…", systemImage: "clock.arrow.circlepath") { managing = agent }
        Divider()
        Button("Delete \(agent.name)", systemImage: "trash", role: .destructive) {
            removing = .agent(agent)
        }
    }

    /// Pending requests, above everything: an agent is waiting on each one, and the owner is the
    /// only one who can answer.
    @ViewBuilder private var pending: some View {
        if !requests.isEmpty {
            VStack(spacing: 0) {
                ForEach(requests) { request in
                    ApprovalRow(request: request) { approve in decide(request, approve) }
                    Divider()
                }
            }
            .background(.bar)
        }
    }

    private func decide(_ request: Approval, _ approve: Bool) {
        Task {
            do {
                try await session.run { try await $0.decide(approval: request.id, approve: approve) }
                requests.removeAll { $0.id == request.id }
                await refresh()
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
        }
    }

    private func remove(_ what: Removal) {
        Task {
            do {
                switch what {
                case .agent(let agent):
                    try await session.run { try await $0.deleteAgent(name: agent.name) }
                    if picked == .agent(agent.name) { picked = nil }
                    previews[ThreadSource.agent(agent.name).key] = nil
                case .thread(let conversation):
                    try await session.run { try await $0.deleteConversation(id: conversation.id) }
                    if picked == .conversation(conversation.id) { picked = nil }
                    previews[ThreadSource.conversation(conversation.id).key] = nil
                    conversations.removeAll { $0.id == conversation.id }
                }
                trouble = nil
                await refresh()
                await refreshConversations()
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
        }
    }

    private func preview(_ source: ThreadSource) -> Message? {
        previews[source.key]
    }

    private func isUnread(_ source: ThreadSource) -> Bool {
        unread.has(source, newest: previews[source.key]?.id)
    }

    /// A worker's subtree is its parent's. Expanding the worker instead would list the worker's
    /// own threads and take the parent's out from under the row the owner just picked.
    private func subtreeOwner(_ name: String) -> String {
        guard let parentId = agents.first(where: { $0.name == name })?.parentId else { return name }
        return agents.first { $0.id == parentId }?.name ?? name
    }

    /// One `?limit=1` per agent alongside the list poll. Fine for the handful of agents one
    /// machine runs; a `lastMessage` on `GET /api/agents` is the upgrade path if it ever hurts.
    private func refresh() async {
        do {
            let rows = try await session.run { try await $0.agents() }
            agents = rows
            requests = (try? await session.run { try await $0.approvals() }) ?? requests
            trouble = nil
            for agent in rows where agent.parentId == nil {
                await loadPreview(.agent(agent.name))
            }
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }

    private func refreshConversations() async {
        guard let expanded,
              let rows = try? await session.run({ try await $0.conversations(agent: expanded) })
        else { return }
        conversations = rows
        for conversation in sharedConversations(rows, expanded) {
            await loadPreview(.conversation(conversation.id))
        }
    }

    private func loadPreview(_ source: ThreadSource) async {
        guard let last = try? await session.run({
            try await $0.messages(source, window: MessageWindow(limit: 1))
        }).last else { return }
        previews[source.key] = last
    }
}

/// One standing request from an agent, and the two buttons that answer it. Nothing is deleted
/// until one of them is pressed, and the agent is told either way.
struct ApprovalRow: View {
    let request: Approval
    let onDecide: (Bool) -> Void

    @Environment(AgentLooks.self) private var looks
    @State private var deciding = false

    private var asks: String {
        switch request.kind {
        case .agent:
            return request.target == request.agent
                ? "wants to delete itself"
                : "wants to delete \(request.target)"
        case .conversation:
            // Its own name is not news to the owner; who else is in the thread is.
            let others = request.participants.filter { $0 != request.agent }
            guard !others.isEmpty else { return "wants to delete its own thread" }
            return "wants to delete its thread with \(others.formatted(.list(type: .and)))"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BloubView(state: .notify, identity: looks[request.agent], size: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(request.agent) \(asks)")
                    .font(.footnote.weight(.medium))
                    .lineLimit(2)
                Text(request.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                HStack(spacing: 8) {
                    Button("Delete it", role: .destructive) { answer(true) }
                        .buttonStyle(.borderedProminent)
                    Button("Keep it") { answer(false) }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
                .disabled(deciding)
                .padding(.top, 3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func answer(_ approve: Bool) {
        deciding = true
        onDecide(approve)
    }
}

struct AgentRow: View {
    let agent: Agent
    let preview: Message?
    let unread: Bool

    @Environment(AgentLooks.self) private var looks

    var body: some View {
        HStack(spacing: 12) {
            BloubView(state: agent.state.bloub, identity: looks[agent.name])

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    StateDot(state: agent.state)
                    Spacer(minLength: 4)
                    if let preview {
                        Text(shortTime(preview.createdAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if unread { UnreadDot() }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// What the agent is doing wins over what it last said: a busy agent is the thing the owner
    /// wants to see at a glance.
    private var subtitle: String {
        if agent.state.busy || agent.state == .failed { return agent.state.label }
        guard let preview else { return agent.state.label }
        if !preview.content.isEmpty { return preview.content.replacingOccurrences(of: "\n", with: " ") }
        if preview.image != nil { return "screenshot" }
        if let call = preview.toolCalls?.first { return call.name }
        return agent.state.label
    }
}

/// A thread an agent shares with somebody. The one it shares with nobody but the owner is reached
/// through the agent itself and is not listed twice.
struct GroupRow: View {
    let conversation: Conversation
    let besides: String
    let preview: Message?
    let unread: Bool

    @Environment(AgentLooks.self) private var looks

    private var others: [String] {
        conversation.participants.filter { $0 != besides }
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: -8) {
                ForEach(others, id: \.self) { name in
                    BloubView(state: .idle, identity: looks[name], size: 26)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("with \(others.formatted(.list(type: .and)))")
                    .font(.subheadline)
                    .lineLimit(1)
                if let preview, !preview.content.isEmpty {
                    Text(preview.content.replacingOccurrences(of: "\n", with: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)
            if unread { UnreadDot() }
        }
        .padding(.leading, 22)
        .padding(.vertical, 2)
    }
}

/// Workers accumulate for as long as an agent runs, so they stay folded away until asked for.
struct WorkersToggle: View {
    let count: Int
    let open: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Label(
                "\(count) task worker\(count == 1 ? "" : "s")",
                systemImage: open ? "chevron.down" : "chevron.right"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.leading, 22)
    }
}

struct WorkerRow: View {
    let agent: Agent

    @Environment(AgentLooks.self) private var looks

    var body: some View {
        HStack(spacing: 10) {
            BloubView(state: agent.state.bloub, identity: looks[agent.name], size: 26)
            Text(agent.name)
                .font(.subheadline)
                .lineLimit(1)
            StateDot(state: agent.state)
            Spacer(minLength: 4)
        }
        .padding(.leading, 22)
        .padding(.vertical, 2)
    }
}

struct NewAgentSheet: View {
    let session: Session
    let onCreated: (Agent) -> Void

    @Environment(AgentLooks.self) private var looks
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var trouble: String?
    @State private var working = false
    /// nil means the look still follows the name, so typing one shows what it would look like.
    @State private var chosen: BloubIdentity?

    private var identity: BloubIdentity {
        chosen ?? .standard(for: wanted)
    }

    private var wanted: String { name.trimmingCharacters(in: .whitespaces) }

    /// The daemon's own rule, checked here so a typed capital is answered as it is typed rather
    /// than by a round trip. The daemon checks it again; this is the keyboard's half.
    private var nameIsFine: Bool { isAgentName(wanted) }

    var body: some View {
        VStack(spacing: 18) {
            Text("New agent")
                .font(.title2.weight(.semibold))
            Text("Lowercase letters, digits and dashes. Creating one makes a Linux user and starts a desktop, so it is slow on purpose.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            BloubView(state: .idle, identity: identity, size: 96)

            TextField("name", text: $name)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .onSubmit(create)

            BloubPicker(identity: Binding(get: { identity }, set: { chosen = $0 }))

            if let trouble {
                Text(trouble)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else if !wanted.isEmpty && !nameIsFine {
                Text("Lowercase letters, digits and dashes, starting with a letter or a digit, up to 31 characters.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(working ? "Creating…" : "Create", action: create)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || !nameIsFine)
            }
        }
        .padding(28)
        // Wide enough for all twelve colours: the picker's rows scroll on a phone, but a Mac sheet
        // sizes to its content and a half-drawn swatch at the edge reads as a bug.
        #if os(macOS)
        .frame(minWidth: 500)
        #else
        .frame(minWidth: 320)
        #endif
    }

    private func create() {
        guard !working, nameIsFine else { return }
        working = true
        trouble = nil
        Task {
            do {
                let agent = try await session.run { try await $0.createAgent(name: wanted) }
                looks[agent.name] = identity
                onCreated(agent)
                dismiss()
            } catch {
                trouble = error.localizedDescription
            }
            working = false
        }
    }
}

func shortTime(_ millis: Int) -> String {
    let date = Date(timeIntervalSince1970: Double(millis) / 1000)
    return Calendar.current.isDateInToday(date)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(date: .abbreviated, time: .omitted)
}
