import SwiftUI

/// The agents as conversation rows — the threads they share listed under them, task workers nested
/// under the agent that spawned them — and the thread of whichever
/// row is picked. `NavigationSplitView` is the sidebar on macOS and regular width and collapses to
/// its own screen on compact.
struct ConsoleView: View {
    let session: Session

    @State private var agents: [Agent] = []
    @State private var goals: [Goal] = []
    /// The newest message of each thread, keyed by `ThreadSource.key`.
    @State private var previews: [String: Message] = [:]
    @State private var selection: SidebarPick?
    /// Whose shared threads are loaded. One agent at a time, as the web UI does it: listing them
    /// for everybody would be another request per agent on every poll.
    @State private var expanded: String?
    @State private var conversations: [Conversation] = []
    @State private var openWorkers: Set<String> = []
    @State private var query = ""
    @State private var trouble: String?
    @State private var creating = false
    /// The settings sheet, and the page it opens on: none for the gear, Models for a refused key.
    @State private var settingsOpen: SettingsRequest?
    #if os(iOS)
    /// The desktop a hand-over was taken from Needs you, presented over everything.
    @State private var takenScreen: Agent?
    #else
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var inspecting = true
    /// The file open beside the chat, if any. One per console: switching threads closes it.
    @State private var artifacts = Artifacts()
    /// Everything waiting on the owner. The sidebar count and the page both read this one list.
    @State private var needs: [NeedsYouItem] = []
    /// The form item whose sheet is up, and the item whose screen to take once it is down.
    @State private var filling: NeedsYouItem?
    @State private var screenAfterForm: NeedsYouItem?
    @State private var removing: Removal?
    @State private var dressing: Agent?
    @State private var managing: Agent?
    @State private var ruling: Agent?
    @State private var idling: Agent?
    /// What the daemon made of the iPhone search field's question.
    @State private var answer: SearchAnswer?
    @State private var asking = false
    @State private var searchTrouble: String?
    /// ⌘K's panel, and the question it opens with.
    @State private var searching: String?
    /// The search hit whose thread is open, kept so the chat can scroll to it and a thread outside
    /// the expanded subtree still has its participants.
    @State private var focus: SearchResult?
    @State private var previewing: URL?
    /// The state each permanent agent was last seen in, so a turn ending while the owner is
    /// looking elsewhere can be announced.
    @State private var lastStates: [String: AgentState] = [:]
    @State private var lastNeedIds: Set<String> = []
    #if DEBUG
    @State private var launchTarget = UserDefaults.standard.string(forKey: "schermes.debugOpen")
    @State private var launchPages: LaunchPages?
    @State private var launchMenuBar = false

    struct LaunchPages: Identifiable {
        let agent: Agent
        let page: AgentPages.Page
        var id: String { agent.name }
    }
    #endif

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

    /// A Mac window stays `.active` behind other apps, so there it also takes the app being in front.
    @State private var frontmost = true
    private var awake: Bool { scenePhase == .active && frontmost }

    /// The owner is at this device: the app in front on a phone, any input in the last two
    /// minutes on a Mac, whose banners then stand in for the phone's pushes.
    private var attending: Bool {
        #if os(macOS)
        awake || CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) < 120
        #else
        awake
        #endif
    }

    enum SidebarPick: Hashable {
        case needsYou
        case goal(Int)
        case thread(ThreadSource)
        /// An agent's settings page in the chat's place, by agent name. Mac only.
        case agentSettings(String)
    }

    /// A whole page in the detail rather than a thread, so there is no agent to inspect.
    private var pickedPage: Bool {
        switch selection {
        case .needsYou, .goal, .agentSettings: true
        case .thread, nil: false
        }
    }

    /// The lead of every helper an open goal still holds, by the helper's name.
    private var helperLeads: [String: String] {
        var leads: [String: String] = [:]
        for goal in goals {
            for helper in goal.temporaryHelpers { leads[helper.name] = goal.lead }
        }
        return leads
    }

    private var picked: ThreadSource? {
        get { if case .thread(let source) = selection { source } else { nil } }
        nonmutating set { selection = newValue.map(SidebarPick.thread) }
    }

    /// `task(id:)` takes one value, and this loop turns on two.
    private struct Pair: Equatable {
        var expanded: String?
        var awake: Bool
        init(_ expanded: String?, _ awake: Bool) {
            self.expanded = expanded
            self.awake = awake
        }
    }

    /// Helpers are listed under their lead, so they are left out of the trees.
    private var trees: [AgentTree] {
        let helpers = helperLeads
        return groupAgents(agents.filter { helpers[$0.name] == nil })
    }

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
                ?? (focus?.conversationId == id ? focus?.participants : nil)
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
        split
        // Keyed by the scene phase: a window nobody is looking at asks less often, and what it
        // finds is announced rather than drawn. On iOS the process is suspended anyway; on a Mac
        // this is what lets a turn finishing behind another app reach the owner.
        .task(id: awake) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(awake ? 2 : 10))
            }
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in frontmost = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in frontmost = false }
        #endif
        .onChange(of: query) { _, now in
            if now.trimmingCharacters(in: .whitespaces).isEmpty {
                answer = nil
                searchTrouble = nil
            }
        }
        #if os(macOS)
        .overlay {
            if let searching {
                SearchOverlay(close: { self.searching = nil }) {
                    SearchPanel(session: session, titles: titles(agents), start: searching, onClose: { self.searching = nil }) { open($0) }
                        .id(searching)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: searching != nil)
        #else
        .sheet(item: Binding(get: { searching.map(SearchStart.init) }, set: { searching = $0?.question })) { start in
            SearchPanel(session: session, titles: titles(agents), start: start.question) { open($0) }
        }
        #endif
        .quickLookPreview($previewing)
        .onAppear { Notifier.ask() }
        // Once per token per daemon: the daemon upserts, so a relaunch that gets the same token
        // costs one request and changes nothing.
        .task(id: registration.token) {
            guard let token = registration.token, token != session.registeredDevice else { return }
            do {
                try await session.run { try await $0.registerDevice(registration, token: token) }
                session.registeredDevice = token
            } catch {
                if !error.isCancellation { registration.failure = "the daemon refused it: \(error.localizedDescription)" }
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
            if next != focus?.thread { focus = nil }
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
        List(selection: $selection) {
            #if os(macOS)
            Button { searching = "" } label: { SidebarSearchRow() }
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityLabel("Search or ask")
                .sidebarRow()

            pickRow(SidebarPick.needsYou) {
                SidebarNeedsYouRow(count: needs.count, selected: selection == .needsYou)
            }
            .sidebarRow()
            .padding(.top, 4)
            #else
            if roomy {
                Button { searching = "" } label: {
                    HStack {
                        Label("Search", systemImage: "magnifyingglass")
                        Spacer()
                        Text("⌘K").font(.caption).foregroundStyle(Theme.muted)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: .command)

                pickRow(SidebarPick.needsYou) {
                    Label("Needs you", systemImage: "bell")
                }
                .badge(needs.count)
            } else if !needs.isEmpty {
                pickRow(SidebarPick.needsYou) {
                    NeedsYouStrip(items: needs, titles: titles(agents))
                }
                .phoneCardRow(true, below: 10)
            }
            #endif

            if !goals.isEmpty, query.isEmpty {
                #if os(macOS)
                Section {
                    ForEach(sortedGoals) { goal in
                        pickRow(SidebarPick.goal(goal.id)) {
                            GoalRow(goal: goal, leadTitle: titles(agents)[goal.lead] ?? goal.lead)
                                .padding(.vertical, 5)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                                .background(
                                    selection == .goal(goal.id) ? AnyShapeStyle(Theme.ink.opacity(0.06)) : AnyShapeStyle(.clear),
                                    in: .rect(cornerRadius: 12)
                                )
                        }
                        .sidebarRow()
                    }
                } header: {
                    SidebarLabel(title: "Goals")
                }
                #else
                if roomy {
                    Section("Goals") {
                        ForEach(sortedGoals) { goal in
                            pickRow(SidebarPick.goal(goal.id)) {
                                GoalRow(goal: goal, leadTitle: titles(agents)[goal.lead] ?? goal.lead)
                            }
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(sortedGoals) { goal in
                                Button { selection = .goal(goal.id) } label: {
                                    GoalCard(goal: goal, leadTitle: titles(agents)[goal.lead] ?? goal.lead)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .phoneCardRow(true, below: 10)
                }
                #endif
            }

            #if os(macOS)
            Section { agentRows } header: { SidebarLabel(title: "Agents") }
            #else
            if roomy {
                Section("Agents") { agentRows }
            } else {
                agentRows
            }
            #endif

            if !roomy, asking || answer != nil || searchTrouble != nil {
                Section("Search") {
                    if let searchTrouble {
                        Text(searchTrouble).font(.callout).foregroundStyle(Theme.failed)
                    }
                    if asking {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    if let answer {
                        UnderstoodAs(answer: answer)
                        ForEach(answer.hits) { hit in
                            Button { open(hit) } label: {
                                ResultRow(result: hit, titles: titles(agents)).contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        #if os(iOS)
        // The Mac keeps the system's glass sidebar; the ground sits behind it in the detail.
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        #endif
        .navigationTitle("Agents")
        #if os(iOS)
        .navigationBarTitleDisplayMode(roomy ? .inline : .large)
        .safeAreaInset(edge: .bottom) {
            if !roomy {
                PhoneHomeBar(query: $query, onSubmit: { Task { await ask() } }, onNew: { creating = true })
            }
        }
        #endif
        .overlay {
            if trees.isEmpty {
                ContentUnavailableView(
                    "No agents yet",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text(trouble ?? "Create one to start talking.")
                )
            } else if visible.isEmpty && answer == nil && !asking && searchTrouble == nil {
                ContentUnavailableView.search(text: query)
            }
        }
        .toolbar {
            #if os(iOS)
            if roomy {
                ToolbarItem {
                    Button("New agent", systemImage: "plus") { creating = true }
                        .keyboardShortcut("n", modifiers: .command)
                }
                // The sidebar's top toolbar is only as wide as the sidebar and a second button
                // there overflows.
                ToolbarItem(placement: .bottomBar) {
                    Button("Settings", systemImage: "gearshape") {
                        settingsOpen = SettingsRequest()
                    }
                        .keyboardShortcut(",", modifiers: .command)
                }
            } else {
                ToolbarItem(placement: .largeTitle) {
                    Text("Agents")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") {
                        settingsOpen = SettingsRequest()
                    }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
            #endif
        }
        // The chat's pill is centred in the window and must clear this column, so with the
        // inspector open a Mac window can shrink only to about twice this width plus 320. At 240
        // that is just under 800.
        .navigationSplitViewColumnWidth(min: 220, ideal: 292, max: 420)
        #if os(macOS)
        // The app menu's Settings… owns ⌘, on the Mac.
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button { creating = true } label: {
                    Label("New agent", systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.pill(.primary))
                .keyboardShortcut("n", modifiers: .command)
                Button { settingsOpen = SettingsRequest() } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 40, height: 40)
                        .accessibilityLabel("Settings")
                }
                .buttonStyle(.pill(.secondary, round: true))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
            .padding(.top, 6)
        }
        .scrollContentBackground(.hidden)
        .onMoveCommand(perform: move)
        .macPanel()
        #endif
        .sheet(item: $dressing) { agent in
            AgentLookSheet(session: session, agent: agent, identity: looks[agent.name])
        }
        .sheet(item: $managing) { agent in
            RoutinesAndActivity(session: session, agent: agent)
        }
        .sheet(item: $ruling) { agent in
            RoutinesAndActivity(session: session, agent: agent, page: .rules)
        }
        .sheet(item: $idling) { agent in
            RoutinesAndActivity(session: session, agent: agent, page: .idle)
        }
        #if DEBUG
        .sheet(item: $launchPages) { pick in
            RoutinesAndActivity(session: session, agent: pick.agent, page: pick.page)
        }
        #if os(macOS)
        .sheet(isPresented: $launchMenuBar) {
            MenuBarPanel(session: session, looks: looks, feed: MenuBarFeed())
        }
        #endif
        #endif
        .sheet(item: $filling, onDismiss: takeScreenAfterForm) { item in
            if let form = item.form {
                FormSheet(agent: titles(agents)[item.agent] ?? item.agent, form: form) { fill in
                    try await session.run { try await $0.fillForm(agent: item.agent, id: form.id, fill: fill) }
                    needs.removeAll { $0.id == item.id }
                    await refresh()
                } onScreen: {
                    screenAfterForm = item
                    filling = nil
                }
            }
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
        .settingsSheet($settingsOpen) { request in
            SettingsSheet(session: session, start: request.start).environment(registration)
        }
        #if os(iOS)
        .fullScreenCover(item: $takenScreen) { agent in
            NavigationStack { DesktopView(session: session, agent: agent) }
        }
        #endif
    }

    /// On the Mac a row is a plain button: the list's own selection highlight would sit over the
    /// fill the row draws, and the list never selects an untagged row.
    @ViewBuilder private func pickRow<Content: View>(_ pick: SidebarPick, @ViewBuilder label: () -> Content) -> some View {
        #if os(macOS)
        Button { selection = pick } label: { label() }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection == pick ? [.isSelected] : [])
        #else
        NavigationLink(value: pick) { label() }
        #endif
    }

    #if os(macOS)
    /// The rows in the order the sidebar shows them, for the arrow keys.
    private var sidebarOrder: [SidebarPick] {
        var order: [SidebarPick] = [.needsYou]
        if query.isEmpty { order += sortedGoals.map { .goal($0.id) } }
        for tree in visible {
            order.append(.thread(.agent(tree.agent.name)))
            order += helpers(of: tree.agent.name).map { .thread(.agent($0.name)) }
            if expanded == tree.agent.name {
                order += sharedConversations(conversations, tree.agent.name).map { .thread(.conversation($0.id)) }
            }
            if query.isEmpty, openWorkers.contains(tree.agent.name) {
                order += tree.workers.map { .thread(.agent($0.name)) }
            }
        }
        return order
    }

    private func move(_ direction: MoveCommandDirection) {
        let order = sidebarOrder
        let index = selection.flatMap { order.firstIndex(of: $0) }
        switch direction {
        case .up: selection = order[max((index ?? order.count) - 1, 0)]
        case .down: selection = order[min((index ?? -1) + 1, order.count - 1)]
        default: break
        }
    }
    #endif

    /// Open goals first, then the newest.
    private var sortedGoals: [Goal] {
        goals.sorted { ($0.isOpen ? 0 : 1, -$0.id) < ($1.isOpen ? 0 : 1, -$1.id) }
    }

    private func helpers(of lead: String) -> [GoalHelper] {
        goals.filter { $0.lead == lead }.flatMap(\.temporaryHelpers)
    }

    @ViewBuilder private var agentRows: some View {
        ForEach(visible) { tree in
            pickRow(SidebarPick.thread(.agent(tree.agent.name))) {
                #if os(macOS)
                SidebarAgentRow(
                    agent: tree.agent,
                    needs: needs.filter { $0.agent == tree.agent.name && $0.kind != .failure },
                    unread: isUnread(.agent(tree.agent.name)),
                    selected: picked == .agent(tree.agent.name) || selection == .agentSettings(tree.agent.name)
                )
                #else
                if roomy {
                    AgentRow(
                        agent: tree.agent,
                        preview: preview(.agent(tree.agent.name)),
                        unread: isUnread(.agent(tree.agent.name))
                    )
                } else {
                    PhoneAgentCard(
                        agent: tree.agent,
                        preview: preview(.agent(tree.agent.name)),
                        waiting: needs.filter { $0.agent == tree.agent.name && $0.kind != .failure }.count,
                        unread: isUnread(.agent(tree.agent.name))
                    )
                }
                #endif
            }
            .sidebarRow()
            .phoneCardRow(!roomy)
            .contextMenu { menu(for: tree.agent) }

            ForEach(helpers(of: tree.agent.name), id: \.name) { helper in
                pickRow(SidebarPick.thread(.agent(helper.name))) {
                    #if os(macOS)
                    SidebarHelperRow(
                        name: helper.name,
                        title: titles(agents)[helper.name] ?? helper.name,
                        lead: tree.agent.name,
                        state: agents.first { $0.name == helper.name }?.state ?? helper.state,
                        selected: picked == .agent(helper.name)
                    )
                    #else
                    HelperRow(
                        name: helper.name,
                        title: titles(agents)[helper.name] ?? helper.name,
                        lead: tree.agent.name,
                        state: agents.first { $0.name == helper.name }?.state ?? helper.state
                    )
                    #endif
                }
                .sidebarRow()
                .phoneCardRow(!roomy)
                .contextMenu {
                    if let agent = agents.first(where: { $0.name == helper.name }), agent.parentId == nil {
                        menu(for: agent)
                    }
                }
            }

            if expanded == tree.agent.name {
                ForEach(sharedConversations(conversations, tree.agent.name)) { conversation in
                    pickRow(SidebarPick.thread(.conversation(conversation.id))) {
                        GroupRow(
                            conversation: conversation,
                            besides: tree.agent.name,
                            titles: titles(agents),
                            preview: preview(.conversation(conversation.id)),
                            unread: isUnread(.conversation(conversation.id))
                        )
                        .sidebarPicked(picked == .conversation(conversation.id))
                    }
                    .phoneCardRow(!roomy)
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
                .phoneCardRow(!roomy)

                if openWorkers.contains(tree.agent.name) {
                    // By name, for the reason `AgentTree.id` gives: a worker row and a thread
                    // row are siblings here, and their `Int` ids come from different sequences.
                    ForEach(tree.workers, id: \.name) { worker in
                        pickRow(SidebarPick.thread(.agent(worker.name))) {
                            WorkerRow(agent: worker).sidebarPicked(picked == .agent(worker.name))
                        }
                        .phoneCardRow(!roomy)
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

    private var detail: some View {
        Group {
            if case .agentSettings(let name) = selection {
                agentSettings(name)
            } else if selection == .needsYou {
                NeedsYouPage(session: session, items: needs, agents: agents, wide: roomy) { item, action in
                    await act(item, action)
                }
            } else if case .goal(let id) = selection {
                if let goal = goals.first(where: { $0.id == id }) {
                    GoalPage(session: session, goal: goal, agents: agents) {
                        await refresh()
                    } onOpenAgent: { name in
                        picked = .agent(name)
                    } onDeleted: {
                        goals.removeAll { $0.id == id }
                        selection = nil
                    }
                } else {
                    ContentUnavailableView("No such goal", systemImage: "flag", description: Text("It may have been deleted."))
                }
            } else if let thread {
                // Mounted fresh per thread, as the web UI keys its Chat by source: without this
                // SwiftUI keeps one view across a switch and a half-typed draft goes to whichever
                // thread the sidebar lands on next. A group thread carries the name of one of its
                // members, so the source rather than the name is what has to be the identity.
                ChatView(
                    session: session,
                    thread: thread,
                    inspector: roomy ? $inspecting : nil,
                    workers: thread.only.map { activeWorkers(of: $0, in: agents) } ?? [],
                    forms: needs.filter { $0.form != nil },
                    onOpenWorker: { worker in
                        if let parent = agents.first(where: { $0.id == worker.parentId }) {
                            openWorkers.insert(parent.name)
                        }
                        picked = .agent(worker.name)
                    },
                    focus: focusedMessage(in: thread.source),
                    onOpenSettings: { if let name = thread.only?.name { selection = .agentSettings(name) } }
                )
                    .id("\(thread.source.key)#\(focusedMessage(in: thread.source) ?? 0)")
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
        #if os(macOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(Theme.ground)
        #if os(macOS)
        .mask { RoundedRectangle(cornerRadius: MacPanel.radius).ignoresSafeArea(edges: .top) }
        #endif
    }

    @ViewBuilder private func agentSettings(_ name: String) -> some View {
        #if os(macOS)
        if let agent = agents.first(where: { $0.name == name }) {
            AgentSettingsPage(session: session, agent: agent) { picked = .agent(name) }
                .id(name)
        } else {
            ContentUnavailableView("No such agent", systemImage: "person.crop.circle.badge.questionmark")
        }
        #endif
    }

    @ViewBuilder private var split: some View {
        #if os(macOS)
        let inspectorShown = roomy && !pickedPage && inspecting
        MacSplit(inspecting: inspectorShown, onInspecting: { inspecting = $0 }) {
            list
        } detail: {
            detail
        } inspector: {
            if roomy && inspecting { inspector }
        }
        // A shut inspector still leaves its divider, which is already the gutter.
        .padding([.leading, .vertical], MacPanel.inset)
        .padding(.trailing, inspectorShown ? MacPanel.inset : 0)
        .ignoresSafeArea()
        #else
        NavigationSplitView {
            list
        } detail: {
            detail
                // Compact width would turn an inspector into a sheet, so there it never opens and the
                // chat keeps its own buttons for the screen and the routines.
                .inspector(isPresented: roomy && !pickedPage ? $inspecting : .constant(false)) {
                    // Built only while shown. SwiftUI keeps an inspector's content alive when it is not
                    // presented — on a compact iPhone it held a second socket to the agent's desktop —
                    // and this content holds one.
                    if roomy && inspecting { inspector }
                }
        }
        #endif
    }

    /// The picked agent's screen and routines. A shared thread has several agents and a task worker
    /// has no desktop, so neither has anything to show here.
    private var inspector: some View {
        Group {
            if let agent = thread?.only, agent.parentId == nil {
                AgentInspector(
                    session: session,
                    agent: agent,
                    goal: goals.first { $0.isOpen && $0.involves(agent.name) },
                    titles: titles(agents),
                    waiting: needs.contains { $0.agent == agent.name && $0.kind != .failure }
                ) { id in
                    selection = .goal(id)
                }
                    .id(agent.name)
            } else {
                ContentUnavailableView(
                    "No screen",
                    systemImage: "display",
                    description: Text("An agent's screen and routines show here. Shared threads and task workers have neither.")
                )
            }
        }
        #if os(macOS)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .macPanel()
        #endif
        .inspectorColumnWidth(min: 220, ideal: 340, max: 420)
    }

    /// What a right-click on an agent offers: the two screens that are otherwise only reachable
    /// from inside its chat, and the one thing that cannot be undone, last and apart.
    @ViewBuilder private func menu(for agent: Agent) -> some View {
        Button("Name and appearance…", systemImage: "paintpalette") { dressing = agent }
        Button("Profile, routines and activity…", systemImage: "clock.arrow.circlepath") { managing = agent }
        Button("Rules…", systemImage: "checkmark.shield") { ruling = agent }
        if agent.parentId == nil {
            Button("When idle…", systemImage: "moon.zzz") { idling = agent }
        }
        Divider()
        Button("Delete \(agent.title)", systemImage: "trash", role: .destructive) {
            removing = .agent(agent)
        }
    }

    private func act(_ item: NeedsYouItem, _ action: NeedsYouAction) async {
        switch action {
        case .approve, .always, .deny:
            guard let approval = item.approval else { return }
            do {
                try await session.run {
                    try await $0.decide(approval: approval.id, approve: action != .deny, always: action == .always)
                }
                needs.removeAll { $0.id == item.id }
                await refresh()
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
        case .retry:
            guard await retry(item) else { return await open(item) }
            await refresh()
        case .settings:
            settingsOpen = SettingsRequest(start: .model)
        case .restartBrowser, .restartDesktop:
            do {
                try await session.run { try await $0.restartBrowser(agent: item.agent, desktop: action == .restartDesktop) }
                needs.removeAll { $0.id == item.id }
                await refresh()
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
        case .screen:
            await open(item)
            if roomy { inspecting = true }
        case .fill:
            await open(item)
            filling = item
        case .takeScreen:
            do {
                _ = try await session.run { try await $0.setControl(agent: item.agent, held: true) }
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
                return
            }
            await open(item)
            #if os(macOS)
            openWindow(id: desktopWindowID, value: item.agent)
            #else
            takenScreen = agents.first { $0.name == item.agent }
            #endif
        case .answer, .open, .other:
            if let goal = item.goalId {
                selection = .goal(goal)
            } else {
                await open(item)
            }
        }
    }

    /// A sheet can't present over one still going away, so the screen waits for the form to close.
    private func takeScreenAfterForm() {
        guard let item = screenAfterForm else { return }
        screenAfterForm = nil
        Task { await act(item, .takeScreen) }
    }

    /// The chat's own Retry, from outside the chat. False when the turn's prompt isn't found or
    /// the owner has written since: then the thread opens, where Retry asks first.
    private func retry(_ item: NeedsYouItem) async -> Bool {
        guard let failure = item.messageId else { return false }
        let source = ThreadSource.conversation(item.conversationId)
        var loaded: [Message] = []
        var before = failure + 1
        // A failed turn can run to hundreds of rows, more than a page, before its prompt.
        for _ in 0..<5 {
            guard let page = try? await session.run({
                try await $0.messages(source, window: MessageWindow(before: before, limit: 200, images: false))
            }) else { return false }
            loaded = page + loaded
            if page.count < 200 || page.contains(where: { $0.role == .user }) { break }
            before = page[0].id
        }
        guard let later = try? await session.run({
            try await $0.messages(source, window: MessageWindow(after: failure, limit: 200, images: false))
        }), let from = retryStart(loaded + later, failure: failure) else { return false }
        do {
            try await session.run { try await $0.rewind(source, from: from, retry: true) }
            return true
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
            return false
        }
    }

    /// An agent's own thread is reached through the agent; a shared one needs its subtree
    /// expanded, whose loop then loads the thread for the detail.
    private func open(_ item: NeedsYouItem) async {
        guard let rows = try? await session.run({ try await $0.conversations(agent: item.agent) }),
              let conversation = rows.first(where: { $0.id == item.conversationId }),
              conversation.participants != [item.agent]
        else {
            picked = .agent(item.agent)
            return
        }
        expanded = subtreeOwner(item.agent)
        picked = .conversation(conversation.id)
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

    private func focusedMessage(in source: ThreadSource) -> Int? {
        focus?.thread == source ? focus?.messageId : nil
    }

    /// A message or screenshot opens its thread at the hit; a file opens in Quick Look, beside
    /// the thread of the agent whose home holds it.
    private func open(_ hit: SearchResult) {
        if let source = hit.thread {
            focus = hit
            if case .conversation = source, let first = hit.participants?.first { expanded = subtreeOwner(first) }
            picked = source
        } else if let agent = hit.agent, let path = hit.path {
            picked = .agent(agent)
            Task {
                do {
                    previewing = try await FileSource(session: session, agent: agent).fetch(path)
                } catch {
                    if !error.isCancellation { trouble = error.localizedDescription }
                }
            }
        }
    }

    private func ask() async {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !asking else { return }
        asking = true
        defer { asking = false }
        do {
            answer = try await session.run { try await $0.ask(question) }
            searchTrouble = nil
        } catch {
            if !error.isCancellation { searchTrouble = error.localizedDescription }
        }
    }

    /// A turn that ended, or something new waiting on the owner, while they were not looking at
    /// this window. Announced once, when the change is first seen.
    private func announce(_ rows: [Agent], _ pending: [NeedsYouItem]) {
        defer {
            lastStates = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.state) })
            lastNeedIds = Set(pending.map(\.id))
        }
        guard !lastStates.isEmpty else { return }
        for agent in rows where agent.parentId == nil {
            guard let before = lastStates[agent.name], before.busy, !agent.state.busy, !awake, attending else { continue }
            let body = agent.state == .failed
                ? "The turn failed."
                : previews[ThreadSource.agent(agent.name).key]?.content.prefix(120).description ?? "Finished."
            Notifier.post(id: "turn:\(agent.name):\(agent.state.rawValue)", title: agent.title, body: body)
        }
        for item in pending where !lastNeedIds.contains(item.id) && !awake && attending {
            let body = item.approval.map { "\($0.kind == .action ? "Asks first" : "Asks to delete something"): \($0.reason)" } ?? item.title
            Notifier.post(
                id: item.id, title: titles(rows)[item.agent] ?? item.agent, body: body,
                category: PushCategory.id(for: item), info: ["needsYou": item.id, "agent": item.agent]
            )
        }
    }

    private func isUnread(_ source: ThreadSource) -> Bool {
        unread.has(source, newest: previews[source.key]?.id)
    }

    /// A worker's subtree is its parent's. Expanding the worker instead would list the worker's
    /// own threads and take the parent's out from under the row the owner just picked.
    private func subtreeOwner(_ name: String) -> String {
        if let lead = helperLeads[name] { return subtreeOwner(lead) }
        guard let parentId = agents.first(where: { $0.name == name })?.parentId else { return name }
        return agents.first { $0.id == parentId }?.name ?? name
    }

    /// One `?limit=1` per agent alongside the list poll. Fine for the handful of agents one
    /// machine runs; a `lastMessage` on `GET /api/agents` is the upgrade path if it ever hurts.
    private func refresh() async {
        do {
            let attending = attending
            let rows = try await session.run { try await $0.agents(attending: attending) }
            if agents != rows { agents = rows }
            looks.adopt(rows)
            let pending = (try? await session.run { try await $0.needsYou() }) ?? needs
            if needs != pending { needs = pending }
            let listed = (try? await session.run { try await $0.goals() }) ?? goals
            if goals != listed { goals = listed }
            trouble = nil
            for agent in rows where agent.parentId == nil {
                await loadPreview(.agent(agent.name))
            }
            announce(rows, needs)
            #if DEBUG
            openLaunchTarget()
            #endif
            Notifier.badge(rows.filter { $0.parentId == nil && isUnread(.agent($0.name)) }.count + needs.count)
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }

    #if DEBUG
    /// `-schermes.debugOpen <target>` opens a screen once at launch, so a test reaches it without
    /// clicking: `needs-you`, `goal:<id>`, `agent:<name>`, `bare:<name>` (inspector hidden), `agent-settings:<name>`, `look:<name>` (name and appearance), `search:<question>`, `pages:<name>:<Page raw value>`, `new-agent`, `menu-bar` (Mac, as a sheet) or `settings` (its
    /// tab from `-schermes.settingsTab`).
    private func openLaunchTarget() {
        guard let target = launchTarget else { return }
        launchTarget = nil
        let parts = target.split(separator: ":", maxSplits: 2).map(String.init)
        switch (parts.first, parts.count) {
        case ("needs-you", 1):
            selection = .needsYou
        case ("goal", 2):
            guard let id = Int(parts[1]) else { return trouble = "No goal id in -schermes.debugOpen \(target)" }
            selection = .goal(id)
        case ("agent", 2):
            picked = .agent(parts[1])
        case ("agent-settings", 2):
            selection = .agentSettings(parts[1])
        case ("look", 2):
            dressing = agents.first { $0.name == parts[1] }
        case ("bare", 2):
            picked = .agent(parts[1])
            inspecting = false
        case ("pages", 3):
            guard let agent = agents.first(where: { $0.name == parts[1] }),
                  let page = AgentPages.Page(rawValue: parts[2])
            else { return trouble = "No agent or page for -schermes.debugOpen \(target)" }
            picked = .agent(agent.name)
            launchPages = LaunchPages(agent: agent, page: page)
        case ("search", 2):
            if roomy {
                searching = parts[1]
            } else {
                query = parts[1]
                Task { await ask() }
            }
        case ("new-agent", 1):
            creating = true
        #if os(macOS)
        case ("menu-bar", 1):
            launchMenuBar = true
        #endif
        case ("settings", 1):
            let tab = UserDefaults.standard.string(forKey: SettingsCategory.storageKey).flatMap(SettingsCategory.init)
            settingsOpen = SettingsRequest(start: tab)
        default:
            trouble = "Unknown -schermes.debugOpen target: \(target)"
        }
    }
    #endif

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

struct AgentRow: View {
    let agent: Agent
    let preview: Message?
    let unread: Bool

    @Environment(AgentLooks.self) private var looks

    var body: some View {
        HStack(spacing: 12) {
            BloubView(state: agent.state.bloub, identity: looks[agent.name], size: 44)
                .busyHalo(agent.state.busy, color: looks[agent.name].color)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(agent.title)
                        .font(.body.weight(unread ? .bold : .semibold))
                        .fontDesign(.rounded)
                        .layoutPriority(1)
                    if let tagline = agent.tagline {
                        Text(tagline)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 4)
                    if let preview {
                        Text(shortTime(preview.createdAt))
                            .font(.caption2)
                            .foregroundStyle(Theme.muted)
                    }
                }
                .lineLimit(1)
                StateLine(state: agent.state, identity: looks[agent.name])
                HStack(spacing: 6) {
                    if let lastLine = previewLine(preview) {
                        Text(lastLine)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if unread { UnreadDot() }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

func previewLine(_ preview: Message?) -> String? {
    guard let preview else { return nil }
    if preview.isIdleNote { return idleSender }
    if preview.isRestoreLine { return "Files put back" }
    if preview.isShownLine { return "Showed how it's done" }
    if preview.isTriggerLine { return preview.content.contains(" is on: ") ? "Trigger turned on" : "Trigger fired" }
    if preview.isSystemLine { return preview.systemLabel }
    if !preview.content.isEmpty { return plainPreview(preview.content) }
    if preview.image != nil { return "screenshot" }
    return preview.toolCalls?.first?.name
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("with")
                    ForEach(others, id: \.self) { name in
                        HStack(spacing: 4) {
                            BloubView(state: .idle, identity: looks[name], size: 20)
                            Text(titles[name] ?? name).fontWeight(.semibold).fontDesign(.rounded)
                        }
                    }
                }
                .font(.subheadline)
                .lineLimit(1)
                .accessibilityElement(children: .combine)
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
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text("\(count) task worker\(count == 1 ? "" : "s")")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(minHeight: 28)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.leading, 22)
    }
}

struct WorkerRow: View {
    let agent: Agent
    var inset: CGFloat = 22

    @Environment(AgentLooks.self) private var looks

    var body: some View {
        HStack(spacing: 10) {
            BloubView(state: agent.state.bloub, identity: looks[agent.name], size: 28)
                .busyHalo(agent.state.busy, color: looks[agent.name].color)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.title)
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.rounded)
                    .lineLimit(1)
                StateLine(state: agent.state, identity: looks[agent.name])
            }
            Spacer(minLength: 4)
        }
        .padding(.leading, inset)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

func shortTime(_ millis: Int) -> String {
    let date = Date(timeIntervalSince1970: Double(millis) / 1000)
    return Calendar.current.isDateInToday(date)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(date: .abbreviated, time: .omitted)
}

private struct SearchStart: Identifiable {
    let question: String
    var id: String { question }
}

extension View {
    /// An iPhone home row on the ground: no list background, no separator, no chevron.
    @ViewBuilder func phoneCardRow(_ on: Bool, below: CGFloat = 4) -> some View {
        #if os(iOS)
        if on {
            listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: below, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .navigationLinkIndicatorVisibility(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
/// An agent on the iPhone home: its own card in its thread's tint.
struct PhoneAgentCard: View {
    let agent: Agent
    let preview: Message?
    /// Its Needs you items other than a failure, which the state line already says.
    let waiting: Int
    let unread: Bool

    @Environment(AgentLooks.self) private var looks
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let identity = looks[agent.name]
        let palette = identity.palette(dark: scheme == .dark)
        HStack(spacing: 12) {
            BloubView(state: agent.state.bloub, identity: identity, size: 48)
                .busyHalo(agent.state.busy, color: identity.color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(agent.title)
                        .font(.system(.body, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .layoutPriority(1)
                    if let tagline = agent.tagline {
                        Text(tagline).font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                if waiting > 0 && agent.state != .failed {
                    HStack(spacing: 4) {
                        Image(systemName: "bell")
                        Text("Needs you")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.needsYou)
                } else {
                    StateLine(state: agent.state, identity: identity)
                }
                if let line = previewLine(preview) {
                    Text(line).font(.footnote).foregroundStyle(Theme.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if waiting > 0 {
                CountCapsule(
                    count: waiting,
                    fill: AnyShapeStyle(palette.bubble.color),
                    text: AnyShapeStyle(palette.bubbleText.color)
                )
            } else if unread {
                UnreadDot()
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .background(palette.tint.color, in: .rect(cornerRadius: 20))
        .contentShape(.rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

/// The iPhone home's floating bar: the search field and New agent.
struct PhoneHomeBar: View {
    @Binding var query: String
    let onSubmit: () -> Void
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Search or ask", text: $query)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(onSubmit)
                if !query.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Theme.muted)
                }
            }
            .font(.callout)
            .padding(.horizontal, 18)
            .frame(minHeight: 52)
            .background(Theme.card.opacity(0.86), in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.card.opacity(0.95)))
            .shadow(color: .black.opacity(0.1), radius: 14, y: 8)
            Button("New agent", systemImage: "plus", action: onNew)
                .labelStyle(.iconOnly)
                .font(.title2)
                .frame(width: 52, height: 52)
                .foregroundStyle(Theme.onInk)
                .background(Theme.ink, in: .circle)
                .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
#endif
