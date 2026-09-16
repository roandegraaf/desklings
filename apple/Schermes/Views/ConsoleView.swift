import SwiftUI

/// The agents as conversation rows — the threads they share listed under them, task workers nested
/// under the agent that spawned them — and the thread of whichever
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
    #if os(iOS)
    @State private var settingsOpen = false
    #endif
    @State private var inspecting = true
    /// The file open beside the chat, if any. One per console: switching threads closes it.
    @State private var artifacts = Artifacts()
    /// What an agent has asked the owner to delete and nobody has answered yet.
    @State private var requests: [Approval] = []
    @State private var removing: Removal?
    @State private var dressing: Agent?
    @State private var managing: Agent?
    /// What the daemon found for the search box across every thread.
    @State private var hits: [SearchHit] = []
    /// The state each permanent agent was last seen in, so a turn ending while the owner is
    /// looking elsewhere can be announced.
    @State private var lastStates: [String: AgentState] = [:]
    @State private var lastRequestIds: Set<Int> = []

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
            case .agent(let agent): "Delete \(agent.title)?"
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

    @Environment(AgentLooks.self) private var looks
    @Environment(Unread.self) private var unread
    @Environment(PushRegistration.self) private var registration
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
            tree.agent.title.lowercased().contains(needle)
                || tree.agent.name.lowercased().contains(needle)
                || preview(.agent(tree.agent.name))?.content.lowercased().contains(needle) == true
        }
    }

    private var thread: ChatThread? {
        switch picked {
        case .agent(let name):
            guard let agent = agents.first(where: { $0.name == name }) else { return nil }
            return .agent(agent)
        case .conversation(let id):
            // A search hit can open a thread under an agent whose subtree is not the expanded one.
            guard let participants = conversations.first(where: { $0.id == id })?.participants
                ?? hits.first(where: { $0.conversationId == id })?.participants
            else { return nil }
            return .group(
                id: id,
                members: agents.filter { participants.contains($0.name) }
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
                        .environment(artifacts)
                        .modifier(ArtifactSplit(artifacts: artifacts, roomy: roomy))
                        .onChange(of: thread.source) { artifacts.open = nil }
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
        // Keyed by the scene phase: a window nobody is looking at asks less often, and what it
        // finds is announced rather than drawn. On iOS the process is suspended anyway; on a Mac
        // this is what lets a turn finishing behind another app reach the owner.
        .task(id: awake) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(awake ? 2 : 10))
            }
        }
        // Debounced: a search is a request to the daemon, not a filter over what is loaded.
        .task(id: query) {
            let needle = query.trimmingCharacters(in: .whitespaces)
            guard needle.count >= 2 else {
                hits = []
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled,
                  let found = try? await session.run({ try await $0.search(needle) })
            else { return }
            hits = found
        }
        .onAppear { Notifier.ask() }
        // Once per token per daemon: the daemon upserts, so a relaunch that gets the same token
        // costs one request and changes nothing.
        .task(id: registration.token) {
            guard let token = registration.token, token != session.registeredDevice else { return }
            if (try? await session.run({ try await $0.registerDevice(registration, token: token) })) != nil {
                session.registeredDevice = token
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAgent)) { note in
            if let name = note.object as? String { picked = .agent(name) }
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
            NewAgentSheet(session: session, taken: Set(agents.map(\.name))) { agent in
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
                                titles: titles(agents),
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

                if !tree.workers.isEmpty, query.isEmpty {
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

            if !hits.isEmpty {
                Section("Messages") {
                    ForEach(hits) { hit in
                        NavigationLink(value: source(of: hit)) {
                            HitRow(hit: hit, titles: titles(agents))
                        }
                    }
                }
            }
        }
        .navigationTitle("Agents")
        // A large title scrolls under the top inset, so it reads as a smudge behind the pending
        // row's material rather than as a title.
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $query, placement: .sidebar, prompt: "Search agents and messages")
        .safeAreaInset(edge: .top) { pending }
        .overlay {
            if trees.isEmpty {
                ContentUnavailableView(
                    "No agents yet",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text(trouble ?? "Create one to start talking.")
                )
            } else if visible.isEmpty && hits.isEmpty {
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
        // behind an overflow chevron: the settings gear lives under the list instead.
        // The chat's pill is centred in the window and must clear this column, so with the
        // inspector open a Mac window can shrink only to about twice this width plus 320. At 240
        // that is just under 800.
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 420)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                #if os(macOS)
                // The `Settings` scene owns ⌘, on the Mac, so the gear only has to open it.
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                #else
                Button("Settings", systemImage: "gearshape") { settingsOpen = true }
                    .keyboardShortcut(",", modifiers: .command)
                #endif
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.body)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .sheet(item: $dressing) { agent in
            AgentLookSheet(session: session, agent: agent, identity: looks[agent.name])
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
        #if os(iOS)
        .sheet(isPresented: $settingsOpen) { SettingsSheet(session: session) }
        #endif
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

    /// What a right-click on an agent offers: the two screens that are otherwise only reachable
    /// from inside its chat, and the one thing that cannot be undone, last and apart.
    @ViewBuilder private func menu(for agent: Agent) -> some View {
        Button("Name and appearance…", systemImage: "paintpalette") { dressing = agent }
        Button("Profile, routines and activity…", systemImage: "clock.arrow.circlepath") { managing = agent }
        Divider()
        Button("Delete \(agent.title)", systemImage: "trash", role: .destructive) {
            removing = .agent(agent)
        }
    }

    /// Pending requests, above everything: an agent is waiting on each one, and the owner is the
    /// only one who can answer.
    @ViewBuilder private var pending: some View {
        if !requests.isEmpty {
            VStack(spacing: 0) {
                ForEach(requests) { request in
                    ApprovalRow(request: request, titles: titles(agents)) { approve in
                        decide(request, approve)
                    }
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

    /// An agent's own thread is reached through the agent; every other one by its id.
    private func source(of hit: SearchHit) -> ThreadSource {
        if hit.participants.count == 1, let only = hit.participants.first {
            return .agent(only)
        }
        return .conversation(hit.conversationId)
    }

    /// A turn that ended, or a request that arrived, while the owner was not looking at this
    /// window. Announced once, when the change is first seen.
    private func announce(_ rows: [Agent], _ pending: [Approval]) {
        defer {
            lastStates = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.state) })
            lastRequestIds = Set(pending.map(\.id))
        }
        guard !lastStates.isEmpty else { return }
        for agent in rows where agent.parentId == nil {
            guard let before = lastStates[agent.name], before.busy, !agent.state.busy, !awake else { continue }
            let body = agent.state == .failed
                ? "The turn failed."
                : previews[ThreadSource.agent(agent.name).key]?.content.prefix(120).description ?? "Finished."
            Notifier.post(id: "turn:\(agent.name):\(agent.state.rawValue)", title: agent.title, body: body)
        }
        for request in pending where !lastRequestIds.contains(request.id) && !awake {
            Notifier.post(id: "approval:\(request.id)", title: titles(rows)[request.agent] ?? request.agent, body: "Asks to delete something: \(request.reason)")
        }
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
            if agents != rows { agents = rows }
            looks.adopt(rows)
            let pending = (try? await session.run { try await $0.approvals() }) ?? requests
            if requests != pending { requests = pending }
            trouble = nil
            for agent in rows where agent.parentId == nil {
                await loadPreview(.agent(agent.name))
            }
            announce(rows, requests)
            Notifier.badge(rows.filter { $0.parentId == nil && isUnread(.agent($0.name)) }.count + requests.count)
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
            try await $0.messages(source, window: MessageWindow(limit: 1, images: false))
        }).last else { return }
        if previews[source.key] != last { previews[source.key] = last }
    }
}

/// One standing request from an agent, and the two buttons that answer it. Nothing is deleted
/// until one of them is pressed, and the agent is told either way.
struct ApprovalRow: View {
    let request: Approval
    /// The owner's word for each agent: a request names them by name.
    let titles: [String: String]
    let onDecide: (Bool) -> Void

    @Environment(AgentLooks.self) private var looks
    @State private var deciding = false

    private func title(_ name: String) -> String { titles[name] ?? name }

    private var asks: String {
        switch request.kind {
        case .agent:
            return request.target == request.agent
                ? "wants to delete itself"
                : "wants to delete \(title(request.target))"
        case .conversation:
            // Its own name is not news to the owner; who else is in the thread is.
            let others = request.participants.filter { $0 != request.agent }.map(title)
            guard !others.isEmpty else { return "wants to delete its own thread" }
            return "wants to delete its thread with \(others.formatted(.list(type: .and)))"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BloubView(state: .notify, identity: looks[request.agent], size: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(title(request.agent)) \(asks)")
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
                    Text(agent.title)
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
        if !preview.content.isEmpty { return plainPreview(preview.content) }
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
    let titles: [String: String]
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
                Text("with \(others.map { titles[$0] ?? $0 }.formatted(.list(type: .and)))")
                    .font(.subheadline)
                    .lineLimit(1)
                if let preview, !preview.content.isEmpty {
                    Text(plainPreview(preview.content))
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

/// One message a search found, under the thread it is in. Opening it opens that thread at its
/// newest row; the hit itself is somewhere above.
struct HitRow: View {
    let hit: SearchHit
    let titles: [String: String]

    private var who: String {
        hit.message.sender.map { titles[$0] ?? $0 } ?? "You"
    }

    private var thread: String {
        hit.participants.map { titles[$0] ?? $0 }.formatted(.list(type: .and))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(who)
                    .font(.caption.weight(.medium))
                Text("in \(thread)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(shortTime(hit.message.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Text(hit.message.content.replacingOccurrences(of: "\n", with: " "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

struct WorkerRow: View {
    let agent: Agent

    @Environment(AgentLooks.self) private var looks

    var body: some View {
        HStack(spacing: 10) {
            BloubView(state: agent.state.bloub, identity: looks[agent.name], size: 26)
            Text(agent.title)
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
    /// The names already in use, so the slug this sheet derives is one the daemon will accept.
    let taken: Set<String>
    let onCreated: (Agent) -> Void

    @Environment(AgentLooks.self) private var looks
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var trouble: String?
    @State private var working = false
    /// nil means the look still follows the name, so typing one shows what it would look like.
    @State private var chosen: BloubIdentity?

    private var identity: BloubIdentity {
        chosen ?? .standard(for: slug)
    }

    private var wanted: String { name.trimmingCharacters(in: .whitespaces) }

    /// What the agent runs as, derived from what the owner typed and shown before they commit to
    /// it: it is the Linux user, the other agents' address for it, and it never changes after.
    private var slug: String { agentName(for: wanted, taken: taken) }

    /// The daemon's own rule, checked here so an empty or overlong name is answered as it is
    /// typed rather than by a round trip. The daemon checks it again; this is the keyboard's half.
    private var nameIsFine: Bool { isAgentLabel(wanted) }

    var body: some View {
        VStack(spacing: 18) {
            Text("New agent")
                .font(.title2.weight(.semibold))
            Text("Call it whatever you like. Creating one makes a Linux user and starts a desktop, so it is slow on purpose.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            BloubView(state: .idle, identity: identity, size: 96)

            TextField("name", text: $name)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
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
                Text("One line, up to \(MAX_AGENT_LABEL) characters.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else if nameIsFine {
                Text("Runs as agent-\(slug)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
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
                let agent = try await session.run {
                    try await $0.createAgent(name: slug, label: wanted, look: identity.token)
                }
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

func shortTime(_ millis: Int) -> String {
    let date = Date(timeIntervalSince1970: Double(millis) / 1000)
    return Calendar.current.isDateInToday(date)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(date: .abbreviated, time: .omitted)
}
