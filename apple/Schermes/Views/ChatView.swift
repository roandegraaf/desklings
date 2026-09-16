import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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
        members.map(\.title).joined(separator: " + ")
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
    /// The agent's pages, presented on the one a command or the toolbar asked for.
    @State private var pages: AgentPages.Page?
    @State private var stopping = false
    /// Which row of the command list Return would run, from the top; wraps at either end.
    @State private var chosen = 0
    /// What the last command came to, where an error would go, in a quieter colour.
    @State private var notice: String?
    /// `/new`, waiting on a yes: the whole thread goes, which is more than a rewind.
    @State private var clearing = false
    @State private var picking = false
    @State private var pickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    /// Files waiting to go with the next message, uploaded on send into the agent's `~/uploads`.
    @State private var attachments: [Attachment] = []
    @FocusState private var editing: Bool
    #if os(macOS)
    @State private var pasteMonitor: Any?
    #endif
    /// How far the reader had got when this thread was opened, captured before it is marked seen
    /// so the divider stays where it was as more arrives. A send from here retires it: the reply
    /// to what the owner just wrote is not news, and an owner row polled in from another client
    /// looks the same as a routine firing, so only this client's own send counts.
    @State private var mark = 0
    /// A rewind that would also take later messages of the owner's with it, waiting on a yes.
    @State private var confirming: Rewind?

    /// Whether the reader is at the newest row, which is what decides if new rows pull the view down.
    @State private var atBottom = true
    @State private var prepending = false
    /// On while the reader is at the newest row, off once they scroll away from it.
    @State private var following = true
    /// A tool line the reader just opened or closed grows downwards, under the pointer, instead of
    /// being pushed up by the bottom anchor. Released on its own: an anchor that changes in the same
    /// update as new rows is applied to them too late.
    @State private var holding = false
    /// A scroll view drops anchor adjustments while a finger or a fling is moving it, so an older
    /// page that arrives mid-scroll waits here for the scroll to settle.
    @State private var phase = ScrollPhase.idle
    @State private var heldPage: [Message]?
    /// The first page and the owner's own send jump to the newest row once it is laid out; asked
    /// for in the same update that adds the row, the scroll view cannot find it yet.
    @State private var jumpPending = false
    @State private var position = ScrollPosition(edge: .bottom)

    @Environment(AgentLooks.self) private var looks
    @Environment(Unread.self) private var unread
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// By id rather than `scrollTo(edge:)`: in a lazy stack the edge is an estimate, and landing on
    /// it left the view scrolled past rows that were never laid out.
    private func hold() {
        holding = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            holding = false
        }
    }

    private func scrollToNewest() {
        following = true
        if live != nil {
            position.scrollTo(id: "live", anchor: .bottom)
        } else if let last = items.last {
            position.scrollTo(id: last.id, anchor: .bottom)
        }
    }

    private var followAnchor: UnitPoint { following && !holding ? .bottom : .top }

    private struct Extent: Equatable {
        var height: CGFloat
        /// Where the view is, in the terms `scrollTo(y:)` takes: those count from below the top
        /// inset, and `contentOffset` does not.
        var target: CGFloat
        init(_ geometry: ScrollGeometry) {
            height = geometry.contentSize.height
            target = geometry.contentOffset.y + geometry.contentInsets.top
        }
    }

    private static func isAtBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.visibleRect.maxY >= geometry.contentSize.height + geometry.contentInsets.bottom - 40
    }

    @ViewBuilder private var jumpToBottom: some View {
        if !atBottom && !loaded.isEmpty {
            Button("Scroll to bottom", systemImage: "arrow.down") {
                withAnimation(reduceMotion ? nil : .snappy) { scrollToNewest() }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .padding(.bottom, 8)
            .transition(.opacity)
        }
    }

    private var items: [ChatItem] {
        let dayStarts = dayStarts
        let unreadId = firstUnread(in: loaded, after: mark)
        return chatItems(loaded, breaks: { dayStarts.contains($0.id) || $0.id == unreadId })
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                // Keyed by the oldest row rather than fired when the top comes near: a page that folds
                // into the tool line already there adds no height, the top stays near, and a
                // trigger on nearness changing would never fire again.
                if more {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .task(id: oldestId(loaded)) { await older() }
                }

                let unreadId = firstUnread(in: loaded, after: mark)
                let dayStarts = dayStarts
                ForEach(items) { item in
                    let message = item.first
                    if dayStarts.contains(message.id) {
                        DaySeparator(millis: message.createdAt)
                    }
                    if message.id == unreadId {
                        NewDivider()
                    }
                    switch item {
                    case .message(let message, let shown):
                        MessageRow(
                            session: session,
                            message: message,
                            shown: shown,
                            own: thread.only?.name,
                            members: thread.members,
                            onRestore: rewindable(restoring: message).map { request in { ask(request) } },
                            onRetry: rewindable(retrying: message).map { request in { ask(request) } }
                        )
                    case .tools(let run):
                        ToolRun(run: run, loaded: loaded, by: thread.only == nil ? speaker(of: run[0], among: thread.members) : nil)
                    }
                }

                if let live, let agent = thread.only {
                    LiveRow(reply: live, agent: agent.title).id("live")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .environment(\.holdScroll, hold)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(followAnchor, for: .sizeChanges)
        .scrollPosition($position)
        .onScrollGeometryChange(for: Bool.self, of: Self.isAtBottom) { _, now in
            atBottom = now
            if now { following = true } else if phase == .interacting || phase == .decelerating { following = false }
        }
        // A `.sizeChanges` anchor does not hold a lazy stack still when rows land above it, so the
        // offset moves by exactly what the older page added.
        .onScrollGeometryChange(for: Extent.self, of: Extent.init) { old, new in
            guard new.height != old.height else { return }
            if jumpPending {
                jumpPending = false
                scrollToNewest()
            } else if prepending {
                prepending = false
                if followAnchor == .top { position.scrollTo(y: old.target + new.height - old.height) }
            } else if followAnchor == .bottom {
                // A jump by id leaves the position pinned to that row and the `.sizeChanges` anchor
                // stops applying, so a reply streaming in below it grew out of view. Scrolling to
                // the edge hands the position back to the anchor.
                position.scrollTo(edge: .bottom)
            }
        }
        .onScrollPhaseChange { _, next in
            phase = next
            if next == .idle, let page = heldPage {
                heldPage = nil
                prepend(page)
            }
        }
        .overlay(alignment: .bottom) {
            jumpToBottom.animation(.easeOut(duration: 0.15), value: atBottom)
        }
        .overlay {
            if loaded.isEmpty && !more {
                if let agent = thread.only, agent.parentId == nil, agent.profile == nil {
                    // A new agent has nothing to say until it knows what it is for. The same
                    // request the Profile page sends, offered where the owner lands first.
                    ContentUnavailableView {
                        Label("\(agent.title) is new", systemImage: "person.crop.circle.badge.questionmark")
                    } description: {
                        Text("It has no profile yet. Let it interview you about what it should be and do; you can also just write to it.")
                    } actions: {
                        Button("Set up \(agent.title)") {
                            Task { await send(interviewRequest(hasProfile: false)) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sending || agent.state.busy)
                    }
                } else {
                    ContentUnavailableView("Nothing here yet", systemImage: "text.bubble")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .confirmationDialog(
            "Later messages will be removed",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { request in
            Button(request.retry ? "Retry" : "Restore", role: .destructive) { Task { await rewind(request) } }
        } message: { _ in
            Text("Everything after this point is deleted from the thread. What the agent already did on its computer stays done.")
        }
        .navigationTitle(thread.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        // The pill already names the thread; the plain title beside it is the same words twice.
        .toolbar(removing: .title)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) { pill.padding(.horizontal, 8) }
            // Only a permanent agent: `desktopAgent` refuses a task worker a display, and a worker
            // holds no schedules of its own — the web UI gives it neither tab. One menu on compact
            // width, where three buttons beside the pill would not fit.
            if let agent = thread.only, agent.parentId == nil, inspector == nil {
                ToolbarItem {
                    Menu {
                        Button("Screen", systemImage: "display") { watching = true }
                        Button("Profile, routines and memory", systemImage: "clock.arrow.circlepath") { pages = .profile }
                        export
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            // Here rather than in the split view: a macOS toolbar lays out whatever is declared
            // before the centred pill to its left, and a parent's items are declared first.
            if let inspector {
                ToolbarSpacer(.flexible)
                ToolbarItem { export }
                ToolbarItem {
                    Button("Inspector", systemImage: "sidebar.trailing") { inspector.wrappedValue.toggle() }
                }
            } else if thread.only?.parentId != nil || thread.only == nil {
                ToolbarItem { export }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                attach(name: url.lastPathComponent, data: data, asImage: isImageFile(url))
            }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photos, matching: .images)
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            photos = []
            Task {
                for item in picked {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    attach(name: "photo", data: data, asImage: true)
                }
            }
        }
        #if os(macOS)
        // A screenshot dragged in from the Finder or the desktop, or an image from another app.
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        guard let data, let url = URL(dataRepresentation: data, relativeTo: nil),
                              let bytes = try? Data(contentsOf: url)
                        else { return }
                        Task { @MainActor in attach(name: url.lastPathComponent, data: bytes, asImage: isImageFile(url)) }
                    }
                } else {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                        guard let data else { return }
                        Task { @MainActor in attach(name: "image", data: data, asImage: true) }
                    }
                }
            }
            return true
        }
        // A pasted screenshot goes with the message; pasted text is the field's own. Not
        // `onPasteCommand`: the text view inside the editor answers `paste:` before SwiftUI
        // asks, and it refuses an image, so Command-V is taken off the event queue instead.
        .onAppear {
            guard pasteMonitor == nil else { return }
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard editing, event.charactersIgnoringModifiers == "v",
                      event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                      pasteImages()
                else { return event }
                return nil
            }
        }
        .onDisappear {
            pasteMonitor.map(NSEvent.removeMonitor)
            pasteMonitor = nil
        }
        #endif
        .sheet(isPresented: $dressing) {
            if let agent = thread.only {
                AgentLookSheet(session: session, agent: agent, identity: looks[agent.name])
            }
        }
        .sheet(item: $pages) { page in
            if let agent = thread.only {
                RoutinesAndActivity(session: session, agent: agent, page: page)
            }
        }
        .confirmationDialog("Clear this thread?", isPresented: $clearing, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { Task { await clear() } }
        } message: {
            Text("Every message and summary in it is deleted. What the agents did on their computers stays done.")
        }
        .onChange(of: draft) { chosen = 0 }
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

    /// The thread as it is loaded, as a Markdown file. What is on screen, not the whole thread:
    /// pages the reader has not walked back to are not fetched for this.
    private var export: some View {
        ShareLink(
            item: ThreadExport(messages: loaded, title: thread.title, titles: titles(thread.members)),
            preview: SharePreview(thread.title)
        ) {
            Label("Export as Markdown", systemImage: "square.and.arrow.up")
        }
        .disabled(loaded.isEmpty)
    }

    @ViewBuilder private var pill: some View {
        if let agent = thread.only {
            // The pill is also the way into the agent's look: there is nowhere else the owner is
            // already looking at the avatar they want to change.
            Button { dressing = true } label: {
                HStack(spacing: 7) {
                    BloubView(state: agent.state.bloub, identity: looks[agent.name], size: 22)
                    Text(agent.title).font(.headline)
                    StateDot(state: agent.state)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(agent.title), \(agent.state.label). Change its name and appearance")
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
            VStack(spacing: 8) {
                Text("A task worker reports to the agent that spawned it. Write to that agent instead.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if thread.only?.state.busy == true { stopButton }
            }
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
                } else if let notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }

                // Keyed by the call, so a second round of questions starts from a blank form.
                if let agent = thread.only, !agent.state.busy, let interview = pendingInterview(in: loaded) {
                    InterviewCard(interview: interview, agent: agent.title) { text in
                        await send(text)
                    }
                    .id(interview.callId)
                }

                if !matches.isEmpty {
                    CommandPalette(commands: matches, picked: picked) { complete($0) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                VStack(spacing: 0) {
                    if !attachments.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(attachments) { attachment in
                                    Group {
                                        if let image = attachment.image {
                                            ScreenshotView(image: image, fit: CGSize(width: 120, height: 64))
                                        } else {
                                            Label(attachment.name, systemImage: "doc")
                                                .lineLimit(1)
                                                .font(.caption)
                                                .padding(.horizontal, 12)
                                                .frame(height: 64)
                                                .background(.fill.tertiary, in: .rect(cornerRadius: 12))
                                        }
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        Button("Remove", systemImage: "xmark.circle.fill") {
                                            attachments.removeAll { $0.id == attachment.id }
                                        }
                                        .labelStyle(.iconOnly)
                                        .buttonStyle(.plain)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.55))
                                        .padding(4)
                                    }
                                }
                            }
                            .padding(.top, 10)
                            .padding(.horizontal, 12)
                        }
                        .scrollIndicators(.hidden)
                    }

                    HStack(spacing: 8) {
                        // Only where there is one agent to hand the file to: a shared thread has
                        // several homes and a worker has none of its own.
                        if let agent = thread.only, agent.parentId == nil {
                            Menu {
                                Button("Photo…", systemImage: "photo") { pickingPhotos = true }
                                Button("File…", systemImage: "doc") { picking = true }
                            } label: {
                                Label("Attach", systemImage: "paperclip")
                            }
                            .labelStyle(.iconOnly)
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .foregroundStyle(.secondary)
                            .disabled(sending)
                        }

                        // Not a vertical `TextField`: on macOS that one clips past its line limit and
                        // ignores the scroll wheel. The editor is sized by a copy of the draft underneath,
                        // which doubles as the placeholder: inside the split view its own height is zero.
                        Text(draft.isEmpty ? placeholder : draft + " ")
                            .lineLimit(5)
                            .foregroundStyle(.tertiary)
                            .opacity(draft.isEmpty ? 1 : 0)
                            .padding(.horizontal, 5)
                            #if os(iOS)
                            .padding(.vertical, 8)
                            #endif
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityHidden(true)
                            .overlay {
                                TextEditor(text: $draft)
                                    .scrollContentBackground(.hidden)
                                    .accessibilityLabel(placeholder)
                                    // An ignored Shift+Return reaches the editor, which puts the newline at the caret.
                                    // With the command list open, Return takes the picked row instead.
                                    .onKeyPress(.return, phases: .down) { press in
                                        if press.modifiers.contains(.shift) { return .ignored }
                                        if let picked { complete(picked) } else if canSend { Task { await send() } }
                                        return .handled
                                    }
                                    .onKeyPress(.upArrow) { move(-1) }
                                    .onKeyPress(.downArrow) { move(1) }
                                    .onKeyPress(.tab) {
                                        guard let picked else { return .ignored }
                                        complete(picked)
                                        return .handled
                                    }
                                    .focused($editing)
                            }
                            .font(.body)

                        if thread.only?.state.busy == true { stopButton }

                        Button("Send", systemImage: "arrow.up") { Task { await send() } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.circle)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!canSend)
                    }
                    .padding(.leading, thread.only?.parentId == nil && thread.only != nil ? 12 : 18)
                    .padding(.trailing, 6)
                    .padding(.vertical, 6)
                }
                .glassEffect(.regular, in: attachments.isEmpty ? AnyShape(.capsule) : AnyShape(.rect(cornerRadius: 24)))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .animation(reduceMotion ? nil : .snappy, value: matches.isEmpty)
        }
    }

    private var matches: [SlashCommand] { commandMatches(draft, in: thread) }

    private var picked: SlashCommand? {
        matches.isEmpty ? nil : matches[min(chosen, matches.count - 1)]
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !matches.isEmpty else { return .ignored }
        chosen = (min(chosen, matches.count - 1) + step + matches.count) % matches.count
        return .handled
    }

    /// A command that takes something is put in the composer for it; the rest run at once.
    private func complete(_ command: SlashCommand) {
        if command.argument != nil {
            draft = "/\(command.rawValue) "
        } else {
            draft = ""
            Task { await run(command, argument: "") }
        }
    }

    private func run(_ command: SlashCommand, argument: String) async {
        trouble = nil
        notice = nil
        switch command {
        case .new:
            clearing = true
        case .compact:
            await compact()
        case .stop:
            if thread.members.contains(where: \.state.busy) { stop() } else { notice = "Nothing is running." }
        case .retry:
            let reply = loaded.last { $0.role == .assistant }
            if let request = reply.flatMap(rewindable(retrying:)) { ask(request) } else { refuseRewind("no reply to ask again") }
        case .undo:
            let mine = loaded.last(where: \.isOwner)
            if let request = mine.flatMap(rewindable(restoring:)) { ask(request) } else { refuseRewind("no message of yours to take back") }
        case .remember:
            await remember(argument)
        case .interview:
            if let agent = thread.only { await send(interviewRequest(hasProfile: agent.profile != nil)) }
        case .screen:
            if let inspector { inspector.wrappedValue = true } else { watching = true }
        case .profile:
            pages = .profile
        case .routines:
            pages = .routines
        case .activity:
            pages = .activity
        case .memory:
            pages = .memory
        }
    }

    private func refuseRewind(_ why: String) {
        trouble = rewindAllowed ? "There is \(why)." : "Stop the turn first."
    }

    /// `rewind` from the first id there is: every row and every summary goes, the thread stays.
    /// Not a delete of the conversation, which would leave a shared thread's row — and its
    /// place in the sidebar — gone from under this view.
    private func clear() async {
        do {
            try await session.run { try await $0.rewind(thread.source, from: 1, retry: false) }
            live = nil
            await open()
            mark = Int.max
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }

    private func compact() async {
        notice = "Folding the thread into a summary…"
        do {
            let result = try await session.run { try await $0.compact(thread.source) }
            notice = compactionNotice(result, titles: titles(thread.members))
        } catch {
            notice = nil
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }

    /// The owner's own line in `MEMORY.md`, through the same read-and-rewrite the Memory page
    /// uses, so nothing the agent wrote is lost around it.
    private func remember(_ note: String) async {
        guard let agent = thread.only else { return }
        guard !note.isEmpty else {
            trouble = "Say what to remember: /remember <note>"
            return
        }
        do {
            let files = try await session.run { try await $0.memory(agent: agent.name) }
            _ = try await session.run {
                try await $0.saveMemory(agent: agent.name, lasting: withNote(files.lasting, note))
            }
            notice = "Added to \(agent.title)'s lasting memory."
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }

    private var canSend: Bool {
        !sending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    /// Ends the agent's turn where it stands. Escape, as the chat apps have it; the daemon
    /// answers the press that lands after the turn ended by itself with a plain no.
    private var stopButton: some View {
        Button(stopping ? "Stopping…" : "Stop", systemImage: "stop.fill") { stop() }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(.red)
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(stopping)
            .accessibilityLabel("Stop the turn")
    }

    /// An image is scaled and encoded the moment it is picked, so the strip can show it and a
    /// send has nothing left to do; bytes that are not an image are refused with a word.
    private func attach(name: String, data: Data, asImage: Bool) {
        if asImage {
            guard let image = inlineImage(from: data) else {
                trouble = "\(name) is not an image that can be sent"
                return
            }
            attachments.append(Attachment(name: name, data: Data(), image: image))
        } else {
            attachments.append(Attachment(name: name, data: data))
        }
    }

    #if os(macOS)
    /// The images on the pasteboard: a copied screenshot, or image files copied in the Finder.
    /// False leaves the key press to the editor, so text still pastes as text.
    private func pasteImages() -> Bool {
        let board = NSPasteboard.general
        if let data = board.data(forType: .png) ?? board.data(forType: .tiff) {
            attach(name: "pasted", data: data, asImage: true)
            return true
        }
        let urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter(isImageFile)
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            attach(name: url.lastPathComponent, data: data, asImage: true)
        }
        return !urls.isEmpty
    }
    #endif

    /// Every agent in the thread that is mid-turn: one behind an agent's own thread, any number
    /// behind a shared one.
    private func stop() {
        let busy = thread.members.filter(\.state.busy)
        guard !busy.isEmpty, !stopping else { return }
        stopping = true
        Task {
            do {
                for agent in busy { _ = try await session.run { try await $0.stop(agent: agent.name) } }
                trouble = nil
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            stopping = false
        }
    }

    private var placeholder: String {
        thread.only.map { "Write to \($0.title)" } ?? "Write to this thread"
    }

    private var dayStarts: Set<Int> {
        Set(loaded.indices.filter { index in
            index == 0 || !Calendar.current.isDate(
                date(loaded[index - 1].createdAt),
                inSameDayAs: date(loaded[index].createdAt)
            )
        }.map { loaded[$0].id })
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
            jumpPending = !page.isEmpty
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
        do {
            let page = try await session.run {
                try await $0.messages(thread.source, window: MessageWindow(before: before))
            }
            if phase != .idle { heldPage = page } else { prepend(page) }
        } catch {
            loadingOlder = false
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }

    private func prepend(_ page: [Message]) {
        let before = items.count
        loaded = merge(loaded, page)
        // Rows that only join the tool line on top add no item and no height, and a flag left up
        // would shift the view at the next unrelated change instead.
        prepending = items.count != before
        more = !atStart(page, PAGE)
        loadingOlder = false
    }

    private var rewindAllowed: Bool {
        !thread.isWorker && !thread.members.contains { $0.state.busy }
    }

    private func rewindable(restoring message: Message) -> Rewind? {
        guard rewindAllowed, message.isOwner else { return nil }
        return Rewind(message: message, from: message.id, retry: false)
    }

    /// A retry asks again the message the reply answered, so everything after that message goes,
    /// the tool work leading up to the reply included.
    private func rewindable(retrying message: Message) -> Rewind? {
        guard rewindAllowed, message.role == .assistant,
              let prompt = loaded.last(where: { $0.id < message.id && $0.role == .user })
        else { return nil }
        return Rewind(message: message, from: prompt.id + 1, retry: true)
    }

    private func ask(_ request: Rewind) {
        if loaded.contains(where: { $0.isOwner && $0.id >= request.from && $0.id != request.message.id }) {
            confirming = request
        } else {
            Task { await rewind(request) }
        }
    }

    private func rewind(_ request: Rewind) async {
        trouble = nil
        do {
            try await session.run { try await $0.rewind(thread.source, from: request.from, retry: request.retry) }
            if !request.retry {
                draft = [request.message.content, draft].filter { !$0.isEmpty }.joined(separator: "\n\n")
                if let image = request.message.image {
                    attachments.append(Attachment(name: "image", data: Data(), image: image))
                }
            }
            await open()
            mark = Int.max
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
        } else if live != next {
            live = next
        }
    }

    /// A form's answers go the way a typed message does, ahead of whatever was in the composer.
    private func send(_ answers: String) async {
        draft = [answers, draft].filter { !$0.isEmpty }.joined(separator: "\n\n")
        await send()
    }

    private func send() async {
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        // A command is the owner's, not the agent's: it never becomes a row. Files waiting to go
        // with a message make it a message, whatever it starts with.
        if attachments.isEmpty, let parsed = parseCommand(text, in: thread) {
            draft = ""
            await run(parsed.command, argument: parsed.argument)
            return
        }
        sending = true
        trouble = nil
        notice = nil
        // Held before the send: rows the daemon wrote in the seconds since the last poll sit
        // between it and the sent row, and merging only the sent row would step over them.
        let cursor = newestId(loaded)
        do {
            // Files first, so the message can name where they landed. One that fails stops the
            // send with the daemon's reason, and the rest stay attached for the retry.
            let files = attachments.filter { $0.image == nil }
            if let agent = thread.only, !files.isEmpty {
                var paths: [String] = []
                for attachment in files {
                    let landed = try await session.run {
                        try await $0.upload(agent: agent.name, name: attachment.name, data: attachment.data)
                    }
                    paths.append(landed.path)
                }
                text += (text.isEmpty ? "" : "\n\n") + "Attached: " + paths.joined(separator: ", ")
            }
            // Images ride inline, one message each, the text going with the first: a message
            // carries one image, and the model sees each as what the owner saw.
            var images = attachments.compactMap(\.image)
            var sent: [Message] = []
            repeat {
                let image = images.isEmpty ? nil : images.removeFirst()
                let message = try await session.run { try await $0.send(thread.source, text: text, image: image) }
                sent.append(message)
                text = ""
            } while !images.isEmpty
            draft = ""
            attachments = []
            mark = Int.max
            loaded = merge(loaded, sent)
            jumpPending = true
            await catchUp(after: cursor)
        } catch {
            trouble = error.localizedDescription
        }
        sending = false
    }
}

struct Rewind: Identifiable {
    let message: Message
    let from: Int
    let retry: Bool
    var id: Int { message.id }
}

/// A file waiting in the composer. Kept as bytes, because a security-scoped URL from the file
/// picker cannot be reopened later from another task. An image is kept already encoded for the
/// wire, and goes inline on the message rather than into `~/uploads`.
struct Attachment: Identifiable {
    let id = UUID()
    var name: String
    var data: Data
    var image: Base64Image? = nil
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

    /// Only a reply that calls nothing is an answer. Words said alongside calls are the agent
    /// narrating its work, and they fold in with the calls they came with.
    var hasBubble: Bool { role != .tool && toolCalls == nil }
}

struct MessageRow: View {
    let session: Session
    let message: Message
    var shown: [Base64Image] = []
    /// The agent whose own thread this is, so its name is not repeated over every row it wrote.
    /// A shared thread has none, and there every sender is worth naming.
    let own: String?
    /// The agents in this thread, for the owner's word and the avatar of whoever wrote a row.
    let members: [Agent]
    var onRestore: (() -> Void)?
    var onRetry: (() -> Void)?

    @Environment(\.colorScheme) private var scheme
    @Environment(AgentLooks.self) private var looks
    @State private var hovering = false
    @State private var copied = false

    private var isOwner: Bool { message.isOwner }

    /// A `user` row with a sender in a two-agent thread is one writing to the other, and reads
    /// nothing like that agent's reply to the owner unless the label says so.
    private var speakerLabel: String? {
        guard let sender = message.sender, sender != own else { return nil }
        let name = titles(members)[sender] ?? sender
        if message.role == .user, members.count == 2, let other = members.first(where: { $0.name != sender }) {
            return "\(name) to \(other.title)"
        }
        return name
    }

    /// Concrete colours rather than `.primary` over `.background`: those two resolve against the
    /// same environment, so setting one changes what the other means and the bubble disappears.
    private var ownerFill: Color { scheme == .dark ? Color(white: 0.92) : Color(white: 0.13) }
    private var ownerInk: Color { scheme == .dark ? Color(white: 0.09) : .white }

    var body: some View {
        HStack {
            if isOwner { Spacer(minLength: 40) }
            VStack(alignment: isOwner ? .trailing : .leading, spacing: 2) {
                ForEach(Array(([message.image].compactMap { $0 } + shown).enumerated()), id: \.offset) { _, image in
                    ScreenshotView(image: image).padding(.bottom, 4)
                }
                bubble
                #if os(macOS)
                // Hidden rather than removed, so a row does not change height under the pointer.
                actions.opacity(hovering ? 1 : 0)
                #else
                if !isOwner { actions }
                #endif
            }
            if !isOwner { Spacer(minLength: 40) }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if !message.content.isEmpty {
                action(copied ? "Copied" : "Copy", copied ? "checkmark" : "doc.on.doc") { copy() }
            }
            if let onRetry { action("Retry", "arrow.clockwise", onRetry) }
            if let onRestore { action("Restore to this message", "arrow.uturn.backward", onRestore) }
        }
        .foregroundStyle(.secondary)
    }

    private func action(_ title: String, _ symbol: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.caption)
                #if os(iOS)
                .frame(width: 36, height: 32)
                #else
                .frame(width: 24, height: 20)
                #endif
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func copy() {
        copyToPasteboard(message.content)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private var bubble: some View {
        VStack(alignment: isOwner ? .trailing : .leading, spacing: 6) {
            if let speakerLabel, let sender = message.sender {
                HStack(spacing: 5) {
                    BloubView(
                        state: members.first { $0.name == sender }?.state.bloub ?? .idle,
                        identity: looks[sender],
                        size: 16
                    )
                    Text(speakerLabel)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            if !message.content.isEmpty {
                if isOwner {
                    if let answers = interviewAnswers(message.content) {
                        InterviewAnswers(answers: answers)
                    } else {
                        Text(message.content).textSelection(.enabled)
                    }
                } else {
                    MarkdownText(
                        content: message.content,
                        files: message.role == .assistant ? message.sender.map { FileSource(session: session, agent: $0) } : nil
                    )
                }
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
        .contextMenu {
            if !message.content.isEmpty {
                Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(message.content) }
            }
            if let onRetry { Button("Retry", systemImage: "arrow.clockwise", action: onRetry) }
            if let onRestore { Button("Restore to this message", systemImage: "arrow.uturn.backward", action: onRestore) }
        }
    }
}

/// A stretch of tool traffic folded into one summary line, screenshots included.
struct ToolRun: View {
    let run: [Message]
    let loaded: [Message]
    /// Who did it, in a thread where several agents work. An agent's own thread names nobody.
    var by: String? = nil

    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(run) { message in
                        if message.role == .assistant, !message.content.isEmpty {
                            MarkdownText(content: message.content)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                        }
                        ToolRow(
                            message: message,
                            name: toolName(for: message, in: loaded),
                            orphaned: isOrphanTool(message, loaded)
                        )
                    }
                }
                .padding(.top, 4)
            } label: {
                Text(by.map { "\($0): \(toolSummary(run))" } ?? toolSummary(run))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }

        }
        .padding(.horizontal, 6)
        .disclosureGroupStyle(WholeRowDisclosure())
    }
}

extension EnvironmentValues {
    @Entry var holdScroll: () -> Void = {}
}

/// A macOS `DisclosureGroup` answers only its chevron; here the whole line is the control.
struct WholeRowDisclosure: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        Line(configuration: configuration)
    }

    private struct Line: View {
        let configuration: Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.holdScroll) private var holdScroll

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    holdScroll()
                    withAnimation(reduceMotion ? nil : .snappy) { configuration.isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        configuration.label
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.secondary)
                    #if os(iOS)
                    .frame(minHeight: 44)
                    #else
                    .frame(minHeight: 24)
                    #endif
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")

                if configuration.isExpanded { configuration.content }
            }
        }
    }
}

/// Tool traffic, one line per call, expanded on tap. The daemon hangs a screenshot off the tool
/// row, so it is drawn here too.
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
        // An assistant's own words are drawn above its row in the run.
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
                HStack(spacing: 6) {
                    Image(systemName: message.role == .tool ? "arrow.turn.down.left" : "wrench.adjustable")
                        .frame(width: 14)
                    Text(title)
                }
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
            }
            // A disclosure style does not reach into another group's content, so each row sets it.
            .disclosureGroupStyle(WholeRowDisclosure())

            if let image = message.image {
                ScreenshotView(image: image)
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
                    MarkdownText(content: reply.text)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.quaternary, in: .rect(cornerRadius: 18))
            Spacer(minLength: 40)
        }
    }
}
