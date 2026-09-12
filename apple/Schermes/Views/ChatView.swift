import SwiftUI

/// What the chat is reading. An agent's own thread — a task worker's included — is reached through
/// the agent, because a brand new agent has no conversation row until something is written to it;
/// a thread it shares with somebody is reached by its conversation id.
enum ChatThread: Hashable {
    case agent(Agent)
    case group(id: Int, members: [Agent])

    var source: ThreadSource {
        switch self {
        case .agent(let agent): .agent(agent.name)
        case .group(let id, _): .conversation(id)
        }
    }

    var members: [Agent] {
        switch self {
        case .agent(let agent): [agent]
        case .group(_, let members): members
        }
    }

    var title: String {
        members.map(\.name).joined(separator: " + ")
    }

    /// The one agent behind an agent thread. A group has several, so it has no single state to
    /// show and no reply of its own to stream.
    var only: Agent? {
        if case .agent(let agent) = self { return agent }
        return nil
    }

    /// A task worker reports to the agent that spawned it. Taking a message over HTTP would start
    /// it working again, so the owner is shown the reason instead of a composer.
    var isWorker: Bool { only?.parentId != nil }
}

/// One thread. The newest page on open, older pages when the reader reaches the top, new rows by
/// poll, and the reply the model is still writing while the agent is busy.
struct ChatView: View {
    let session: Session
    let thread: ChatThread
    /// The inspector column, where there is room for one. It carries the agent's screen and
    /// routines, so the toolbar offers the column instead of those two buttons.
    let inspector: Binding<Bool>?

    @State private var loaded: [Message] = []
    @State private var more = false
    @State private var live: LiveReply?
    @State private var draft = ""
    @State private var trouble: String?
    @State private var sending = false
    @State private var loadingOlder = false
    @State private var dressing = false
    @State private var watching = false
    @State private var routines = false
    /// How far the reader had got when this thread was opened, captured before it is marked seen
    /// so the divider stays where it was as more arrives. Only a send from here moves it on: an
    /// owner row polled in from another client looks the same as a routine firing.
    @State private var mark = 0

    @Environment(AgentLooks.self) private var looks
    @Environment(Unread.self) private var unread

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if more {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .onAppear { Task { await older() } }
                }

                ForEach(Array(loaded.enumerated()), id: \.element.id) { index, message in
                    if startsADay(index) {
                        DaySeparator(millis: message.createdAt)
                    }
                    if message.id == firstUnread(in: loaded, after: mark) {
                        NewDivider()
                    }
                    MessageRow(message: message, loaded: loaded, own: thread.only?.name)
                }

                if let live, let agent = thread.only {
                    LiveRow(reply: live, agent: agent.name)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
        // Anchoring beats scrolling by hand: the thread opens at the newest row, a reply arriving
        // keeps it there, and a page of older rows prepended above leaves the reader where it was.
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .overlay {
            if loaded.isEmpty && !more {
                ContentUnavailableView("Nothing here yet", systemImage: "text.bubble")
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(thread.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        // The pill already names the thread; the plain title beside it is the same words twice.
        .toolbar(removing: .title)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) { pill }
            // Only a permanent agent: `desktopAgent` refuses a task worker a display, and a worker
            // holds no schedules of its own — the web UI gives it neither tab.
            if let agent = thread.only, agent.parentId == nil, inspector == nil {
                ToolbarItem {
                    Button("Routines and activity", systemImage: "clock.arrow.circlepath") { routines = true }
                }
                ToolbarItem {
                    Button("Screen", systemImage: "display") { watching = true }
                }
            }
            // Here rather than in the split view: a macOS toolbar lays out whatever is declared
            // before the centred pill to its left, and a parent's items are declared first.
            if let inspector {
                ToolbarSpacer(.flexible)
                ToolbarItem {
                    Button("Inspector", systemImage: "sidebar.trailing") { inspector.wrappedValue.toggle() }
                }
            }
        }
        .sheet(isPresented: $dressing) {
            if let agent = thread.only {
                AgentLookSheet(name: agent.name, state: agent.state, identity: looks[agent.name])
            }
        }
        .sheet(isPresented: $routines) {
            if let agent = thread.only {
                RoutinesAndActivity(session: session, agent: agent)
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $watching) { desktop }
        #endif
        // Keyed by the thread, not by the agent's name: a group thread carries the same name as
        // one of its members, so without the whole source a switch between them would keep one
        // view and carry a half-typed draft into the other thread.
        .task(id: thread.source) {
            await open()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await catchUp()
            }
        }
        // Keyed by the whole thread, so the loop restarts with a fresh state every list poll and
        // the `busy` test below is never reading a stale one.
        .task(id: thread) {
            // The reply a model is still writing belongs to one agent. A shared thread would have
            // to ask every participant, so it shows none — the web UI makes the same call.
            guard let agent = thread.only, agent.state.busy else {
                if live != nil {
                    live = nil
                    await catchUp()
                }
                return
            }
            while !Task.isCancelled {
                await pollLive(agent.name)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // Reading the newest row is what marks the thread seen, wherever the row came from: the
        // first page, a poll, an older page, or the owner's own send.
        .onChange(of: loaded.last?.id) { _, newest in
            if let newest { unread.see(thread.source, through: newest) }
        }
    }

    /// Compact width only, where there is no inspector to open it from. Presented rather than
    /// pushed: the detail column is not a `NavigationStack`, and the desktop wants the whole screen.
    @ViewBuilder private var desktop: some View {
        if let agent = thread.only {
            NavigationStack {
                DesktopView(session: session, agent: agent)
            }
        }
    }

    @ViewBuilder private var pill: some View {
        if let agent = thread.only {
            // The pill is also the way into the agent's look: there is nowhere else the owner is
            // already looking at the avatar they want to change.
            Button { dressing = true } label: {
                HStack(spacing: 7) {
                    BloubView(state: agent.state.bloub, identity: looks[agent.name], size: 22)
                    Text(agent.name).font(.headline)
                    StateDot(state: agent.state)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(agent.name), \(agent.state.label). Change appearance")
        } else {
            HStack(spacing: 7) {
                HStack(spacing: -7) {
                    ForEach(thread.members) { member in
                        BloubView(state: member.state.bloub, identity: looks[member.name], size: 22)
                    }
                }
                Text(thread.title).font(.headline)
            }
            .accessibilityLabel("thread with \(thread.title)")
        }
    }

    @ViewBuilder private var composer: some View {
        if thread.isWorker {
            Text("A task worker reports to the agent that spawned it. Write to that agent instead.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        } else {
            VStack(spacing: 6) {
                if thread.only == nil {
                    Text("Agents stop writing to each other after a few messages without you. Posting here is what clears that.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                if let trouble {
                    Text(trouble)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 8)
                }

                HStack(spacing: 8) {
                    TextField(placeholder, text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        // A vertical field takes Return as a newline, which is not what a chat
                        // composer is for. Both branches answer the press: returning `.ignored`
                        // does not hand it on to the field — measured, the key is simply dropped —
                        // so Shift+Return writes its own newline rather than relying on that.
                        // ponytail: the newline goes on the end, because a `TextField` binding is
                        // the whole string and says nothing about where the cursor is. A
                        // `TextEditor` with a selection binding is the upgrade if anyone types
                        // into the middle often enough to mind.
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) {
                                draft += "\n"
                            } else if canSend {
                                Task { await send() }
                            }
                            return .handled
                        }

                    Button("Send", systemImage: "arrow.up") { Task { await send() } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSend)
                }
                .padding(.leading, 18)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }

    private var canSend: Bool {
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var placeholder: String {
        thread.only.map { "Write to \($0.name)" } ?? "Write to this thread"
    }

    private func startsADay(_ index: Int) -> Bool {
        guard index > 0 else { return true }
        let calendar = Calendar.current
        return !calendar.isDate(
            date(loaded[index - 1].createdAt),
            inSameDayAs: date(loaded[index].createdAt)
        )
    }

    private func date(_ millis: Int) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    private func open() async {
        mark = unread.lastSeen(thread.source)
        do {
            let page = try await session.run { try await $0.messages(thread.source) }
            loaded = page
            more = !atStart(page, PAGE)
            trouble = nil
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }

    private func catchUp() async {
        await catchUp(after: newestId(loaded))
    }

    /// Two callers, and the difference between them is the whole point: a poll walks on from the
    /// newest row it holds, a send from the cursor it held before it. `nil` is a real answer — an
    /// empty thread asks for the newest page — so it cannot be spelled as a default.
    private func catchUp(after cursor: Int?) async {
        guard let rows = try? await session.run({
            try await $0.messages(thread.source, window: catchUpWindow(after: cursor))
        }), !rows.isEmpty else { return }
        loaded = merge(loaded, rows)
    }

    private func older() async {
        guard !loadingOlder, let before = oldestId(loaded) else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await session.run {
                try await $0.messages(thread.source, window: MessageWindow(before: before))
            }
            loaded = merge(loaded, page)
            more = !atStart(page, PAGE)
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }

    private func pollLive(_ name: String) async {
        guard let next = try? await session.run({ try await $0.live(agent: name) }) else { return }
        if next.isEmpty {
            if live != nil {
                live = nil
                await catchUp()
            }
        } else {
            live = next
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        trouble = nil
        // Held before the send: rows the daemon wrote in the seconds since the last poll sit
        // between it and the sent row, and merging only the sent row would step over them.
        let cursor = newestId(loaded)
        do {
            let message = try await session.run { try await $0.send(thread.source, text: text) }
            draft = ""
            mark = max(mark, message.id)
            loaded = merge(loaded, [message])
            await catchUp(after: cursor)
        } catch {
            trouble = error.localizedDescription
        }
        sending = false
    }
}

struct DaySeparator: View {
    let millis: Int

    var body: some View {
        Text(Date(timeIntervalSince1970: Double(millis) / 1000)
            .formatted(date: .abbreviated, time: .omitted))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}

/// Where the owner had got to when the thread was opened. Everything below it arrived since.
struct NewDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            rule
            Text("new")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
            rule
        }
        .padding(.vertical, 4)
    }

    private var rule: some View {
        Rectangle()
            .fill(.tint)
            .opacity(0.35)
            .frame(height: 1)
    }
}

/// The row the "new" divider sits above: the first one past the mark. No row's shape says the owner
/// wrote it, because the daemon stores a routine firing exactly like an owner's message.
func firstUnread(in loaded: [Message], after mark: Int) -> Int? {
    loaded.first { $0.id > mark }?.id
}

extension Message {
    /// A `user` row with a sender is another agent's message delivered to this one; without one
    /// it is the owner, and the owner's rows are the ones on the right.
    var isOwner: Bool { role == .user && sender == nil }

    /// The daemon keeps a reply's text and the calls it made on one assistant row, so one row can
    /// be a bubble and a tool line both. A call with nothing said is only the line.
    var hasBubble: Bool { role != .tool && !(content.isEmpty && toolCalls != nil) }
    var hasToolLine: Bool { role == .tool || toolCalls != nil }
}

struct MessageRow: View {
    let message: Message
    let loaded: [Message]
    /// The agent whose own thread this is, so its name is not repeated over every row it wrote.
    /// A shared thread has none, and there every sender is worth naming.
    let own: String?

    @Environment(\.colorScheme) private var scheme

    private var isOwner: Bool { message.isOwner }

    /// Concrete colours rather than `.primary` over `.background`: those two resolve against the
    /// same environment, so setting one changes what the other means and the bubble disappears.
    private var ownerFill: Color { scheme == .dark ? Color(white: 0.92) : Color(white: 0.13) }
    private var ownerInk: Color { scheme == .dark ? Color(white: 0.09) : .white }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if message.hasBubble {
                HStack {
                    if isOwner { Spacer(minLength: 40) }
                    bubble
                    if !isOwner { Spacer(minLength: 40) }
                }
            }
            if message.hasToolLine {
                ToolRow(
                    message: message,
                    name: toolName(for: message, in: loaded),
                    orphaned: isOrphanTool(message, loaded)
                )
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: isOwner ? .trailing : .leading, spacing: 6) {
            if let sender = message.sender, sender != own {
                Text(sender).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            if !message.content.isEmpty {
                Text(message.content).textSelection(.enabled)
            }
            if let image = message.image {
                ScreenshotView(image: image).frame(maxWidth: 420)
            }
            Text(shortTime(message.createdAt))
                .font(.caption2)
                .opacity(0.6)
        }
        .foregroundStyle(isOwner ? AnyShapeStyle(ownerInk) : AnyShapeStyle(.foreground))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isOwner ? AnyShapeStyle(ownerFill) : AnyShapeStyle(.quaternary),
                    in: .rect(cornerRadius: 18))
    }
}

/// Tool traffic, one line per call, expanded on tap. A screenshot observation is the exception:
/// the daemon hangs the image off the tool row, and it is the one piece of tool traffic the owner
/// is meant to see without asking.
struct ToolRow: View {
    let message: Message
    let name: String?
    let orphaned: Bool

    @State private var open = false

    private var title: String {
        if let call = message.toolCalls?.first {
            let more = (message.toolCalls?.count ?? 1) - 1
            return more > 0 ? "\(call.name) +\(more)" : call.name
        }
        return name ?? "result"
    }

    var detail: String {
        var parts: [String] = []
        if orphaned { parts.append("answers a call from further back — load older to see it") }
        for call in message.toolCalls ?? [] { parts.append("\(call.name) \(call.arguments)") }
        // An assistant's own words are already in its bubble.
        if message.role == .tool, !message.content.isEmpty { parts.append(message.content) }
        return parts.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $open) {
                Text(detail)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                Label(title, systemImage: message.role == .tool ? "arrow.turn.down.left" : "wrench.adjustable")
                    .font(.caption)
                    // A concrete colour: iOS draws a disclosure label in the tint, and the
                    // hierarchical `.secondary` there is the tint's, a link blue.
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }

            if let image = message.image {
                ScreenshotView(image: image).frame(maxWidth: 420)
            }
        }
        .padding(.horizontal, 6)
    }
}

/// The reply as the model is still writing it. Gone the moment the stored message arrives.
struct LiveRow: View {
    let reply: LiveReply
    let agent: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(agent) is writing…")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                if !reply.reasoning.isEmpty {
                    Text(reply.reasoning)
                        .font(.caption.italic())
                        .foregroundStyle(.secondary)
                }
                if !reply.text.isEmpty {
                    Text(reply.text)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.quaternary, in: .rect(cornerRadius: 18))
            Spacer(minLength: 40)
        }
    }
}
