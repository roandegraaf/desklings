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
    /// The agent's task workers still at it, pinned above the composer so the owner sees the work
    /// move without unfolding them in the list. Tapping one opens its thread.
    var workers: [Agent] = []
    /// Needs you's form items: the transcript says a form is waiting, the item holds its fields.
    var forms: [NeedsYouItem] = []
    /// Needs you's approval items, answered from the card where the request sits in the thread.
    var requests: [NeedsYouItem] = []
    var onAct: (NeedsYouItem, NeedsYouAction) async -> Void = { _, _ in }
    var onOpenWorker: (Agent) -> Void = { _ in }
    /// A row to open the thread at instead of the newest, as a search hit asks.
    var focus: Int? = nil
    /// The agent's settings page, which takes the chat's place in the detail pane on the Mac.
    var onOpenSettings: () -> Void = {}

    @State private var loaded: [Message] = [] {
        didSet { rows = ChatRows(loaded, mark: mark) }
    }
    /// Everything drawn that follows from `loaded` and `mark` alone, rebuilt when either changes.
    @State private var rows = ChatRows()
    @State private var more = false
    @State private var live: LiveReply?
    @State private var arrivals = Arrivals()
    /// The bubbles the live row has shown, so the stored reply does not show them arriving twice.
    @State private var liveSent: [String] = []
    @State private var thinkingOpen = false
    /// The thinking panel is folding before the reply lands; the other poll must not land it first.
    @State private var folding = false
    @State private var draft = ""
    @State private var trouble: String?
    @State private var sending = false
    @State private var loadingOlder = false
    @State private var dressing = false
    @State private var watching = false
    @State private var filling: NeedsYouItem?
    /// The agent's triggers, fetched only while the chat shows a trigger card.
    @State private var triggers: [Trigger] = []
    /// The thread's approvals, answered ones included, refetched when a request appears or stops waiting.
    @State private var approvals: [Approval] = []
    /// A reply the owner gave a thumbs down, waiting on the optional reason.
    @State private var faulting: Message?
    @State private var forwarder = Forwarder()
    @State private var screenAfterForm = false
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
    @Environment(\.openWindow) private var openWindow
    #endif
    /// How far the reader had got when this thread was opened, captured before it is marked seen
    /// so the divider stays where it was as more arrives. A send from here retires it: the reply
    /// to what the owner just wrote is not news, and an owner row polled in from another client
    /// looks the same as a routine firing, so only this client's own send counts.
    @State private var mark = 0 {
        didSet { rows = ChatRows(loaded, mark: mark) }
    }
    /// A Restore or Retry, waiting on a yes in the preview sheet.
    @State private var confirming: Rewind?

    /// Whether the reader is at the newest row, which is what decides if new rows pull the view down.
    @State private var atBottom = true
    @State private var prepending = false
    /// On while the reader is at the newest row, off once they scroll away from it.
    @State private var following = true
    @State private var scrollHold = ScrollHold()
    /// A scroll view drops anchor adjustments while a finger or a fling is moving it, so an older
    /// page that arrives mid-scroll waits here for the scroll to settle.
    @State private var phase = ScrollPhase.idle
    @State private var heldPage: [Message]?
    /// The first page and the owner's own send jump to the newest row once it is laid out; asked
    /// for in the same update that adds the row, the scroll view cannot find it yet.
    @State private var jumpPending = false
    @State private var focusPending = false
    @State private var position = ScrollPosition(edge: .bottom)

    @Environment(AgentLooks.self) private var looks
    @Environment(Unread.self) private var unread
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// The thread's colours: the agent's own, so every thread is recognisably its agent's. A
    /// shared thread has several and keeps the ground and the app's accent.
    private var palette: AgentPalette? {
        thread.only.map { looks[$0.name].palette(dark: scheme == .dark) }
    }

    private var agentColor: BloubColorId? { thread.only.map { looks[$0.name].color } }
    private var accent: Color { palette?.accentText.color ?? Theme.ink.rgb(dark: scheme == .dark).color }
    private var bubble: Color { palette?.bubble.color ?? Theme.ink.rgb(dark: scheme == .dark).color }
    private var bubbleText: Color { palette?.bubbleText.color ?? Theme.onInk.rgb(dark: scheme == .dark).color }
    private var replyBubble: Color { palette?.soft.color ?? Theme.card.rgb(dark: scheme == .dark).color }
    private var replyLink: Color { palette?.softText.color ?? accent }

    /// By id rather than `scrollTo(edge:)`: in a lazy stack the edge is an estimate, and landing on
    /// it left the view scrolled past rows that were never laid out.
    private func scrollToNewest() {
        following = true
        if live != nil {
            position.scrollTo(id: "live", anchor: .bottom)
        } else if let last = rows.items.last {
            position.scrollTo(id: last.id, anchor: .bottom)
        }
    }

    private var followAnchor: UnitPoint { following && !scrollHold.holding ? .bottom : .top }

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

    @ViewBuilder private func row(_ item: ChatItem) -> some View {
        switch item {
        case .message(let message, _) where message.isIdleNote:
            IdleNoteLine(millis: message.createdAt)
        case .message(let message, _) where message.isTriggerLine:
            TriggerLine(message: message)
        case .message(let message, _) where message.isRestoreLine:
            RestoreLine(message: message)
        case .message(let message, _) where message.isShownLine:
            ShownLine(message: message)
        case .message(let message, _) where message.isSystemLine:
            SystemLine(message: message)
        case .message(let message, let shown):
            MessageRow(
                session: session,
                message: message,
                shown: shown,
                speaker: speakerLabel(of: message, own: thread.only?.name, among: thread.members),
                bubble: bubble,
                bubbleText: bubbleText,
                replyBubble: replyBubble,
                replyLink: replyLink,
                enterFrom: arrivals.from[message.id],
                onRestore: rewindable(restoring: message).map { request in { ask(request) } },
                onRetry: rewindable(retrying: message).map { request in { ask(request) } },
                onFeedback: message.role == .assistant ? { rating in rate(message, rating) } : nil
            )
            .equatable()
        case .tools(let run):
            ToolRun(run: run, by: thread.only == nil ? speaker(of: run[0].message, among: thread.members) : nil)
                .equatable()
        case .request(let step):
            request(step)
        }
    }

    /// Answered from the card while it waits; once answered, its outcome. A request from before
    /// outcomes were kept has no row and stays a tool line.
    @ViewBuilder private func request(_ step: ToolStep) -> some View {
        if let approval = approvals.first(where: { $0.callId == step.message.toolCallId }) {
            if let item = requests.first(where: { $0.approval?.id == approval.id }) {
                NeedsYouCard(item: item, agent: nil, titles: titles(thread.members), onAct: onAct)
            } else {
                ApprovalLine(approval: approval, titles: titles(thread.members))
            }
        } else {
            ToolRun(run: [step], by: thread.only == nil ? speaker(of: step.message, among: thread.members) : nil)
                .equatable()
        }
    }

    private var approvalsKey: [String] { rows.requestCalls + requests.map(\.id) }

    private func loadApprovals() async {
        guard !rows.requestCalls.isEmpty else { return }
        if let fresh = try? await session.run({ try await $0.approvals(thread.source) }) { approvals = fresh }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                // Keyed by the oldest row rather than fired when the top comes near: a page that folds
                // into the tool line already there adds no height, the top stays near, and a
                // trigger on nearness changing would never fire again.
                if more {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .task(id: oldestId(loaded)) { await older() }
                }

                ForEach(rows.items) { item in
                    let message = item.first
                    if rows.dayStarts.contains(message.id) {
                        DaySeparator(millis: message.createdAt)
                    }
                    if message.id == rows.unreadId {
                        NewDivider()
                    }
                    row(item)
                }

                if let live, let agent = thread.only {
                    LiveRow(reply: live, agent: agent.title, bubble: replyBubble, link: replyLink, thinkingOpen: $thinkingOpen) { useBackup in
                        await retryModel(agent.name, useBackup: useBackup)
                    }
                    .id("live")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .frame(maxWidth: readingWidth)
            .frame(maxWidth: .infinity)
            .environment(\.holdScroll, scrollHold)
            .environment(\.arrivals, arrivals)
            .environment(forwarder)
        }
        .task(id: approvalsKey) { await loadApprovals() }
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
            if focusPending {
                focusPending = false
                if let focus, let item = rows.items.last(where: { $0.first.id <= focus }) {
                    position.scrollTo(id: item.id, anchor: .center)
                }
            } else if jumpPending {
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
            if loaded.isEmpty && !more { empty }
        }
        // The content and the composer, not the toolbar. Text-strength: a filled control in the
        // agent's colour sets the bubble colour on itself.
        .tint(accent)
        .background(palette.map { AnyShapeStyle($0.tint.color) } ?? AnyShapeStyle(Theme.ground))
        .safeAreaInset(edge: .bottom) { composer }
        .sheet(item: $confirming) { request in
            RewindSheet(
                retry: request.retry,
                title: { name in thread.members.first { $0.name == name }?.title ?? name },
                load: { try await session.run { try await $0.rewindPreview(thread.source, from: request.from) } },
                confirm: { files in try await rewind(request, files: files) }
            )
        }
        .navigationTitle(thread.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        // The pill already names the thread; the plain title beside it is the same words twice.
        .toolbar(removing: .title)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .principal) { pill.padding(.horizontal, 8) }
            // Only a permanent agent: `desktopAgent` refuses a task worker a display, and a worker
            // holds no schedules of its own — the web UI gives it neither tab. One menu, where three
            // buttons beside the pill would not fit; with an inspector too, which no longer lists the pages.
            if let agent = thread.only, agent.parentId == nil {
                ToolbarItem {
                    Menu {
                        if inspector == nil {
                            Button("Screen", systemImage: "display") { watching = true }
                        }
                        Button("Profile", systemImage: "person.text.rectangle") { pages = .profile }
                        Button("Rules", systemImage: "checkmark.shield") { pages = .rules }
                        Button("When idle", systemImage: "moon.zzz") { pages = .idle }
                        Button("Routines and triggers", systemImage: "bolt.badge.clock") { pages = .routines }
                        Button("Activity", systemImage: "list.bullet.rectangle") { pages = .activity }
                        Button("Memory", systemImage: "book.closed") { pages = .memory }
                        export
                    } label: {
                        if let percent = agent.contextFullness {
                            Image(systemName: "ellipsis")
                                .overlay { ContextRing(percent: percent, identity: looks[agent.name], radius: 11.2) }
                                .accessibilityLabel("More. \(ContextFullness.label(percent))")
                        } else {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                    }
                }
            }
            // Here rather than in the split view: a macOS toolbar lays out whatever is declared
            // before the centred pill to its left, and a parent's items are declared first.
            if let inspector {
                ToolbarSpacer(.flexible)
                if let agent = thread.only, let percent = agent.contextFullness {
                    ToolbarItem { ContextMeter(percent: percent, identity: looks[agent.name]).padding(.horizontal, 6) }
                }
                if thread.only?.parentId != nil || thread.only == nil {
                    ToolbarItem { export }
                }
                ToolbarItem {
                    Button("Inspector", systemImage: "sidebar.trailing") { inspector.wrappedValue.toggle() }
                }
            } else if thread.only?.parentId != nil || thread.only == nil {
                ToolbarItem { export }
            }
            #endif
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
        .task(id: rows.trigger == nil ? nil : thread.only?.name) {
            if rows.trigger != nil, let agent = thread.only, agent.parentId == nil { await watchTriggers(agent.name) }
        }
        .sheet(item: $filling, onDismiss: takeScreenAfterForm) { item in
            if let form = item.form {
                FormSheet(agent: thread.only?.title ?? item.agent, form: form) { fill in
                    let cursor = newestId(loaded)
                    try await session.run { try await $0.fillForm(agent: item.agent, id: form.id, fill: fill) }
                    mark = Int.max
                    jumpPending = true
                    await catchUp(after: cursor)
                } onScreen: {
                    screenAfterForm = true
                    filling = nil
                }
            }
        }
        .sheet(item: $faulting) { message in
            FeedbackSheet { reason in
                try await sendFeedback(message.id, FeedbackUpdate(rating: .down, reason: reason))
            }
        }
        .sheet(item: Binding(get: { forwarder.pending }, set: { forwarder.pending = $0 })) { forwarding in
            ForwardSheet(session: session, forwarding: forwarding, excluding: thread.only?.name)
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
                    await catchUp()
                    live = nil
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
            guard let newest, unread.see(thread.source, through: newest) else { return }
            let source = thread.source
            Task { try? await session.run { try await $0.markRead(source, through: newest) } }
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

    /// Prose reads best under about 80 characters a line; a Mac window is far wider than that.
    private let readingWidth: CGFloat = 760

    /// A thread with nothing in it opens on the face it belongs to, not on a grey glyph. A new
    /// agent is offered the interview here, where the owner lands first, with the same request the
    /// Profile page sends.
    @ViewBuilder private var empty: some View {
        VStack(spacing: 16) {
            if let agent = thread.only {
                BloubView(state: .idle, identity: looks[agent.name], size: 120)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(thread.members) { member in
                        VStack(spacing: 6) {
                            BloubView(state: .idle, identity: looks[member.name], size: 88)
                            Text(member.title).font(.subheadline.weight(.semibold)).fontDesign(.rounded)
                            if let tagline = member.tagline {
                                Text(tagline).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
                            }
                        }
                        .frame(maxWidth: 140)
                    }
                }
            }
            Text(thread.title)
                .font(.title2.weight(.bold))
                .fontDesign(.rounded)
            if let agent = thread.only, agent.parentId == nil, agent.profile == nil {
                Text("It has no profile yet. Let it interview you about what it should be and do, or just start writing to it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Set up \(agent.title)") {
                    Task { await send(interviewRequest(hasProfile: false)) }
                }
                .buttonStyle(.pill(.agent(agentColor)))
                .controlSize(.large)
                .disabled(sending || agent.state.busy)
            } else {
                Text(thread.isWorker ? "Nothing reported yet." : "Nothing here yet. Whatever you write below starts the thread.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 360)
        .padding(24)
    }

    @ViewBuilder private var pill: some View {
        if let agent = thread.only {
            // The pill is also the way into the agent's look: there is nowhere else the owner is
            // already looking at the avatar they want to change.
            Button { dressing = true } label: {
                HStack(spacing: 8) {
                    BloubView(state: agent.state.bloub, identity: looks[agent.name], size: 26)
                        .busyHalo(agent.state.busy, color: looks[agent.name].color)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(agent.title).font(.headline).fontDesign(.rounded)
                        StateLine(state: agent.state, identity: looks[agent.name], font: .caption2.weight(.semibold))
                    }
                }
                .lineLimit(1)
                .padding(.leading, 2)
                .padding(.trailing, 6)
            }
            // The Mac's toolbar already sets its items on glass; iOS leaves a custom principal
            // item bare, so only there does the button bring its own.
            #if os(iOS)
            .buttonStyle(.glass)
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel("\(agent.title), \(agent.state.label). Change its name and appearance")
        } else {
            HStack(spacing: 10) {
                ForEach(thread.members) { member in
                    HStack(spacing: 5) {
                        BloubView(state: member.state.bloub, identity: looks[member.name], size: 22)
                            .busyHalo(member.state.busy, color: looks[member.name].color)
                        Text(member.title).font(.subheadline.weight(.semibold)).fontDesign(.rounded)
                    }
                }
            }
            .lineLimit(1)
            #if os(iOS)
            .padding(.vertical, 5)
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .glassEffect(.regular, in: .capsule)
            #endif
            .accessibilityLabel("thread with \(thread.title)")
        }
    }

    #if os(macOS)
    private var header: some View {
        HStack(spacing: 14) {
            headerTitle
            Spacer(minLength: 0)
            if let agent = thread.only, let percent = agent.contextFullness {
                ContextMeter(percent: percent, identity: looks[agent.name])
                    .padding(.leading, 9)
                    .padding(.trailing, 12)
                    .frame(height: 36)
                    .background(Theme.card.opacity(0.72), in: .capsule)
                    .overlay { Capsule().strokeBorder(Theme.card.opacity(0.95), lineWidth: 1) }
            }
            headerTools
        }
        .padding(EdgeInsets(top: 16, leading: 24, bottom: 10, trailing: 20))
        .background {
            Rectangle()
                .fill(palette.map { AnyShapeStyle($0.tint.color) } ?? AnyShapeStyle(Theme.ground))
                .ignoresSafeArea(edges: .top)
        }
    }

    @ViewBuilder private var headerTitle: some View {
        if let agent = thread.only {
            Button { dressing = true } label: {
                HStack(spacing: 14) {
                    BloubView(state: agent.state.bloub, identity: looks[agent.name], size: 44)
                        .busyHalo(agent.state.busy, color: looks[agent.name].color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.title).font(.system(size: 22, weight: .bold, design: .rounded))
                        StateLine(state: agent.state, identity: looks[agent.name], font: .system(size: 13, weight: .semibold))
                    }
                }
                .lineLimit(1)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Change its name and appearance")
            .accessibilityLabel("\(agent.title), \(agent.state.label). Change its name and appearance")
        } else {
            HStack(spacing: 14) {
                HStack(spacing: -10) {
                    ForEach(thread.members) { member in
                        BloubView(state: member.state.bloub, identity: looks[member.name], size: 34)
                            .busyHalo(member.state.busy, color: looks[member.name].color)
                    }
                }
                Text(thread.title).font(.system(size: 22, weight: .bold, design: .rounded))
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("thread with \(thread.title)")
        }
    }

    private var headerTools: some View {
        HStack(spacing: 2) {
            if let agent = thread.only, agent.parentId == nil {
                headerButton("Routines and triggers", symbol: "bolt.badge.clock") { pages = .routines }
                headerButton("Memory", symbol: "book.closed") { pages = .memory }
                headerButton("\(agent.title)'s settings", symbol: "gearshape", action: onOpenSettings)
            }
            export
                .labelStyle(.iconOnly)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 36)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.ink)
                .help("Export as Markdown")
            if let inspector {
                headerButton(
                    inspector.wrappedValue ? "Hide inspector" : "Show inspector",
                    symbol: "sidebar.trailing",
                    active: inspector.wrappedValue
                ) { inspector.wrappedValue.toggle() }
            }
        }
        .padding(4)
        .background(Theme.card.opacity(0.72), in: .capsule)
        .overlay { Capsule().strokeBorder(Theme.card.opacity(0.95), lineWidth: 1) }
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private func headerButton(_ title: String, symbol: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        let text = active ? palette.map { AnyShapeStyle($0.softText.color) } ?? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.ink)
        let fill = active ? palette.map { AnyShapeStyle($0.soft.color) } ?? AnyShapeStyle(Theme.ink.opacity(0.06)) : AnyShapeStyle(.clear)
        return Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(text)
            .frame(width: 36, height: 36)
            .background(fill, in: .circle)
            .contentShape(.circle)
            .buttonStyle(.plain)
            .help(title)
    }
    #endif

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
            GlassEffectContainer(spacing: 12) {
            VStack(spacing: 10) {
                if thread.only == nil {
                    Text("Agents stop writing to each other after a few messages without you. Posting here is what clears that.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                #if os(macOS)
                if !workers.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { workerChips }
                        VStack(spacing: 8) { workerChips }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                #else
                ForEach(workers) { worker in
                    Button { onOpenWorker(worker) } label: {
                        WorkerRow(agent: worker, inset: 0)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityHint("Opens the worker's thread")
                }
                #endif

                if trouble != nil || notice != nil {
                    HStack(spacing: 10) {
                        Image(systemName: trouble != nil ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(trouble != nil ? AnyShapeStyle(Theme.failed) : AnyShapeStyle(Theme.muted))
                        Text(trouble ?? notice ?? "")
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Dismiss", systemImage: "xmark") {
                            trouble = nil
                            notice = nil
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    #if os(macOS)
                    .floatingCard(radius: 18)
                    #else
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                    #endif
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Keyed by the call, so a second round of questions starts from a blank form.
                if let agent = thread.only, !agent.state.busy, let interview = rows.interview {
                    InterviewCard(interview: interview, agent: agent.title) { text in
                        await send(text)
                    }
                    .id(interview.callId)
                    .actionCard(bubble)
                }

                if let agent = thread.only, agent.parentId == nil, !agent.state.busy, let hang = rows.browserHang {
                    BrowserHungCard(agent: agent.title, onScreen: showScreen) { desktop in
                        await restartBrowser(agent.name, desktop: desktop)
                    }
                    .id(hang)
                    .actionCard(bubble)
                }

                if let agent = thread.only, agent.parentId == nil, !agent.state.busy, let handOver = rows.handOver {
                    HandOverCard(agent: agent.title, reason: handOver.reason) {
                        await takeScreen(agent.name)
                    }
                    .id(handOver.callId)
                    .actionCard(bubble)
                }

                if let agent = thread.only, agent.parentId == nil, !agent.state.busy, let pending = rows.form,
                   let item = forms.first(where: { $0.messageId == pending.messageId }), let form = item.form {
                    FormCard(agent: agent.title, form: form) {
                        filling = item
                    } onScreen: {
                        await takeScreen(agent.name)
                    }
                    .id(pending.callId)
                    .actionCard(bubble)
                }

                // Not held back while the agent is busy: turning it on starts the turn that offers the test.
                if let agent = thread.only, agent.parentId == nil, let pending = rows.trigger,
                   let trigger = triggers.first(where: { $0.id == pending.triggerId }), trigger.state != .off {
                    TriggerCard(
                        trigger: trigger,
                        pending: pending,
                        hookURL: trigger.webhook.flatMap { session.client?.hookURL($0) },
                        onLogin: forms.first(where: { $0.triggerId == trigger.id }).map { item in { filling = item } }
                    ) { action in
                        let updated = try await session.run { try await $0.actOnTrigger(id: trigger.id, action: action) }
                        triggers = triggers.compactMap { $0.id == trigger.id ? updated : $0 }
                    }
                    .id(pending.callId)
                    .actionCard(bubble)
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
                                    #if os(macOS)
                                    .font(.system(size: 16, weight: .medium))
                                    .frame(width: 36, height: 36)
                                    .background(Theme.ink.opacity(0.06), in: .circle)
                                    .contentShape(.circle)
                                    #endif
                            }
                            .labelStyle(.iconOnly)
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            #if os(macOS)
                            .foregroundStyle(Theme.ink)
                            #else
                            .foregroundStyle(.secondary)
                            #endif
                            .accessibilityLabel("Attach a photo or file")
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
                                    .accessibilityLabel(recipient)
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
                            .font(.canvas(15, .body))

                        if thread.only?.state.busy == true { stopButton }

                        Button("Send", systemImage: "arrow.up") { Task { await send() } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.pill(canSend ? .agent(agentColor) : .secondary, round: true))
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!canSend)
                    }
                    #if os(macOS)
                    .padding(.leading, thread.only?.parentId == nil && thread.only != nil ? 8 : 18)
                    #else
                    .padding(.leading, thread.only?.parentId == nil && thread.only != nil ? 12 : 18)
                    #endif
                    .padding(.trailing, 6)
                    .padding(.vertical, 6)
                }
                #if os(macOS)
                .floatingCard(radius: 26, fill: 0.86, shadow: 0.08, blur: 28, y: 8)
                #else
                .glassEffect(.regular, in: attachments.isEmpty ? AnyShape(.capsule) : AnyShape(.rect(cornerRadius: 24)))
                #endif
            }
            .frame(maxWidth: readingWidth)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .animation(reduceMotion ? nil : .snappy, value: matches.isEmpty)
            .animation(reduceMotion ? nil : .snappy, value: trouble == nil && notice == nil)
            .animation(reduceMotion ? nil : .snappy, value: workers.map(\.name))
            .tint(accent)
            }
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
            showScreen()
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
    private func rate(_ message: Message, _ rating: FeedbackRating?) {
        if rating == .down {
            faulting = message
            return
        }
        Task {
            do {
                try await sendFeedback(message.id, FeedbackUpdate(rating: rating))
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
        }
    }

    private func sendFeedback(_ id: Int, _ update: FeedbackUpdate) async throws {
        let stored = try await session.run { try await $0.setFeedback(message: id, update) }
        if let index = loaded.firstIndex(where: { $0.id == id }) { loaded[index].feedback = stored }
    }

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
            .buttonStyle(.pill(.destructive, round: true))
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

    private var recipient: String {
        thread.only.map { "Message \($0.title)" } ?? "Message this thread"
    }

    private var placeholder: String {
        SlashCommand.offered(in: thread).isEmpty ? recipient : recipient + ", or / for commands"
    }

    #if os(macOS)
    private var workerChips: some View {
        ForEach(workers) { worker in
            Button { onOpenWorker(worker) } label: {
                HStack(spacing: 8) {
                    BloubView(state: worker.state.bloub, identity: looks[worker.name], size: 20)
                    Text(worker.title).fontWeight(.bold).foregroundStyle(Theme.ink)
                    StateLine(state: worker.state, identity: looks[worker.name], font: .canvas(12, .caption))
                }
                .font(.canvas(12, .caption))
                .lineLimit(1)
                .padding(.leading, 8)
                .padding(.trailing, 12)
                .frame(height: 32)
                .floatingCard(radius: 16, fill: 0.8, shadow: 0.06, blur: 14, y: 4)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the worker's thread")
        }
    }
    #endif

    private func open() async {
        mark = unread.lastSeen(thread.source)
        do {
            var page = try await session.run { try await $0.messages(thread.source) }
            more = !atStart(page, PAGE)
            if let focus {
                for _ in 0..<10 where more && !page.contains(where: { $0.id <= focus }) {
                    guard let before = oldestId(page) else { break }
                    let older = try await session.run {
                        try await $0.messages(thread.source, window: MessageWindow(before: before))
                    }
                    page = merge(page, older)
                    more = !atStart(older, PAGE)
                }
                following = false
            }
            loaded = page
            if focus != nil, !page.isEmpty { focusPending = true } else { jumpPending = !page.isEmpty }
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
        let newest = newestId(loaded) ?? 0
        let fresh = rows.filter { $0.id > newest }
        let answer = fresh.last { $0.role == .assistant && $0.hasBubble && $0.sender == thread.only?.name }
        if folding { return }
        if answer != nil, thinkingOpen {
            folding = true
            withAnimation(.snappy(duration: 0.25)) { thinkingOpen = false }
            try? await Task.sleep(for: .milliseconds(260))
            folding = false
        }
        if following {
            for row in fresh {
                arrivals.from[row.id] = row.id == answer?.id ? sharedLead(liveSent, bubbleChunks(row.content)) : 0
            }
        }
        loaded = merge(loaded, rows)
        if answer != nil {
            live = nil
            liveSent = []
        }
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
        let before = rows.items.count
        loaded = merge(loaded, page)
        // Rows that only join the tool line on top add no item and no height, and a flag left up
        // would shift the view at the next unrelated change instead.
        prepending = rows.items.count != before
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
        guard rewindAllowed, let from = rows.retryFrom[message.id] else { return nil }
        return Rewind(message: message, from: from, retry: true)
    }

    private func ask(_ request: Rewind) {
        confirming = request
    }

    private func rewind(_ request: Rewind, files: Bool) async throws {
        trouble = nil
        try await session.run { try await $0.rewind(thread.source, from: request.from, retry: request.retry, files: files) }
        if !request.retry {
            draft = [request.message.content, draft].filter { !$0.isEmpty }.joined(separator: "\n\n")
            if let image = request.message.image {
                attachments.append(Attachment(name: "image", data: Data(), image: image))
            }
        }
        await open()
        mark = Int.max
    }

    private func pollLive(_ name: String) async {
        guard let next = try? await session.run({ try await $0.live(agent: name) }) else { return }
        if next.isEmpty {
            if live != nil {
                await catchUp()
                if !folding { live = nil }
            }
        } else if live != next {
            live = next
            liveSent = Array(bubbleChunks(next.text).dropLast())
        }
    }

    private func showScreen() {
        if let inspector { inspector.wrappedValue = true } else { watching = true }
    }

    /// Takes the agent's mouse and keyboard, then opens its desktop where "Give it back" is.
    /// Polled, not pushed: a fire and a login entered elsewhere both change what the card shows.
    private func watchTriggers(_ name: String) async {
        while !Task.isCancelled {
            if let rows = try? await session.run({ try await $0.triggers(agent: name) }) { triggers = rows }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func takeScreen(_ name: String) async {
        do {
            _ = try await session.run { try await $0.setControl(agent: name, held: true) }
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
            return
        }
        #if os(macOS)
        openWindow(id: desktopWindowID, value: name)
        #else
        watching = true
        #endif
    }

    /// A sheet can't present over one still going away, so the screen waits for the form to close.
    private func takeScreenAfterForm() {
        guard screenAfterForm, let name = thread.only?.name else { return }
        screenAfterForm = false
        Task { await takeScreen(name) }
    }

    private func restartBrowser(_ name: String, desktop: Bool) async {
        let cursor = newestId(loaded)
        do {
            try await session.run { try await $0.restartBrowser(agent: name, desktop: desktop) }
            mark = Int.max
            jumpPending = true
            await catchUp(after: cursor)
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }

    private func retryModel(_ name: String, useBackup: Bool) async {
        do {
            try await session.run { try await $0.retryModel(agent: name, useBackup: useBackup) }
            await pollLive(name)
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
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
            for message in sent { arrivals.from[message.id] = 0 }
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

/// Why a reply missed, optional. It goes into the agent's memory with the thumbs down.
struct FeedbackSheet: View {
    let onSend: (String?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var sending = false
    @State private var trouble: String?

    private static let limit = 500

    var body: some View {
        ThemedForm {
            Section {
                TextField("What was wrong with it?", text: $reason, axis: .vertical)
                    .lineLimit(3...8)
                    .onChange(of: reason) { if reason.count > Self.limit { reason = String(reason.prefix(Self.limit)) } }
                if let trouble {
                    Label(trouble, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.failed)
                }
            } footer: {
                Text("Optional. The agent finds it in its memory.")
            }
        }
        .sheetChrome(
            "Bad reply",
            confirm: "Send",
            confirmDisabled: sending,
            cancel: { dismiss() },
            onConfirm: send
        )
        .presentationDetents([.medium])
        .presentationBackground(Theme.ground)
        #if os(macOS)
        .frame(minWidth: 380, idealWidth: 420, minHeight: 220)
        #endif
    }

    private func send() {
        sending = true
        trouble = nil
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await onSend(trimmed.isEmpty ? nil : trimmed)
                dismiss()
            } catch {
                trouble = error.localizedDescription
            }
            sending = false
        }
    }
}

#if os(iOS)
private let dividerFont = Font.caption
#else
private let dividerFont = Font.system(size: 12)
#endif

private let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.doesRelativeDateFormatting = true
    return formatter
}()

struct DaySeparator: View {
    let millis: Int

    var body: some View {
        HStack(spacing: 12) {
            rule
            Text(dayFormatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000)))
                .font(dividerFont.weight(.semibold))
                .foregroundStyle(Theme.muted)
                .fixedSize()
            rule
        }
        .padding(.vertical, 4)
    }

    private var rule: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).accessibilityHidden(true)
    }
}

/// Where an idle pass began: the daemon's note to the agent, which is not the owner speaking.
struct IdleNoteLine: View {
    let millis: Int

    var body: some View {
        Label {
            Text("Idle work · \(Date(timeIntervalSince1970: Double(millis) / 1000).formatted(date: .omitted, time: .shortened))")
        } icon: {
            Image(systemName: "moon.zzz")
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct SystemLine: View {
    let message: Message

    var body: some View {
        Label {
            Text("\(message.systemLabel) · \(Date(timeIntervalSince1970: Double(message.createdAt) / 1000).formatted(date: .omitted, time: .shortened))")
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(Theme.muted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .help(message.content)
        .accessibilityElement(children: .combine)
    }
}

/// Where the owner had got to when the thread was opened. Everything below it arrived since.
struct NewDivider: View {
    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(.tint)
                .opacity(0.45)
                .frame(height: 1)
                .accessibilityHidden(true)
            Text("New")
                .font(dividerFont.weight(.bold))
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
    }
}

/// The row the "new" divider sits above: the first one past the mark. No row's shape says the owner
/// wrote it: routines that fired before the System sender existed are stored like an owner's message.
func firstUnread(in loaded: [Message], after mark: Int) -> Int? {
    loaded.first { $0.id > mark }?.id
}

extension Message {
    /// A `user` row with a sender is another agent's message or a daemon line; without one it is
    /// the owner, and the owner's rows are the ones on the right. Restore lines written before the
    /// System sender have none and are still not the owner speaking.
    var isOwner: Bool { role == .user && sender == nil && !isRestoreLine && !isShownLine }

    /// The daemon's hand-off of a "Show the agent how" recording, stored as the owner's line.
    var isShownLine: Bool { role == .user && sender == nil && content.hasPrefix(shownLinePrefix) }

    var isRestoreLine: Bool {
        role == .user && (sender == nil || sender == systemSender) && content.hasPrefix(restoredLineStart) && content.contains(restoredLineMiddle)
    }

    var isIdleNote: Bool { role == .user && sender == idleSender }

    /// The daemon's line when a trigger fires or is turned on; not the owner speaking either.
    var isTriggerLine: Bool { role == .user && sender == triggerSender }

    var isSystemLine: Bool { role == .user && sender == systemSender }

    var systemLabel: String {
        if content.hasPrefix("The owner approved your request to ") { return "You approved" }
        if content.hasPrefix("Scheduled task ") { return "Routine ran" }
        return systemSender
    }

    /// Only a reply that calls nothing is an answer. Words said alongside calls are the agent
    /// narrating its work, and they fold in with the calls they came with.
    var hasBubble: Bool { role != .tool && toolCalls == nil }
}

struct MessageRow: View, Equatable {
    let session: Session
    let message: Message
    var shown: [Base64Image] = []
    /// The name over the reply, where the thread has more than one voice.
    let speaker: String?
    /// The owner's bubble, flat in the agent's colour, and the text that reads on it.
    let bubble: Color
    let bubbleText: Color
    let replyBubble: Color
    let replyLink: Color
    /// The first bubble to animate in, for a row that arrived while the thread was open.
    var enterFrom: Int? = nil
    var onRestore: (() -> Void)?
    var onRetry: (() -> Void)?
    /// The rating the owner picked, `nil` when they tapped the one already chosen.
    var onFeedback: ((FeedbackRating?) -> Void)?

    @Environment(AgentLooks.self) private var looks
    @Environment(Forwarder.self) private var forwarder: Forwarder?
    @State private var hovering = false
    @State private var copied = false
    @Environment(\.arrivals) private var arrivals

    private var canForward: Bool { forwarder != nil && !message.content.isEmpty }

    private func forward() {
        forwarder?.pending = Forwarding(messageId: message.id)
    }

    private var isOwner: Bool { message.isOwner }

    /// The closures are never equal, so what is compared is whether the row offers each action.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.shown == rhs.shown && lhs.speaker == rhs.speaker
            && lhs.bubble == rhs.bubble && lhs.bubbleText == rhs.bubbleText
            && lhs.replyBubble == rhs.replyBubble && lhs.replyLink == rhs.replyLink
            && lhs.enterFrom == rhs.enterFrom
            && (lhs.onRestore == nil) == (rhs.onRestore == nil)
            && (lhs.onRetry == nil) == (rhs.onRetry == nil)
            && (lhs.onFeedback == nil) == (rhs.onFeedback == nil)
    }

    /// The owner's words sit in a bubble on the right, the agent's on the left, as every chat app
    /// has them. A reply is as many bubbles as it has paragraphs, the way a person texts.
    var body: some View {
        VStack(alignment: isOwner ? .trailing : .leading, spacing: 4) {
            ForEach(Array(([message.image].compactMap { $0 } + shown).enumerated()), id: \.offset) { _, image in
                ScreenshotView(image: image).padding(.bottom, 4)
            }
            if isOwner { ownerBubble } else { reply }
            meta
        }
        .modifier(SendEntrance(active: isOwner && enterFrom != nil))
        .frame(maxWidth: .infinity, alignment: isOwner ? .trailing : .leading)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onAppear { arrivals?.from[message.id] = nil }
        .environment(\.forwardedMessage, message.id)
        .contextMenu {
            if !message.content.isEmpty {
                Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(message.content) }
            }
            if canForward { Button("Send to…", systemImage: "arrowshape.turn.up.right") { forward() } }
            if let onRetry { Button("Retry", systemImage: "arrow.clockwise", action: onRetry) }
            if let onRestore { Button("Restore to this message", systemImage: "arrow.uturn.backward", action: onRestore) }
            if onFeedback != nil {
                Divider()
                ForEach([FeedbackRating.up, .down], id: \.self) { rating in
                    Button(thumbTitle(rating), systemImage: thumbSymbol(rating)) { thumb(rating) }
                }
            }
        }
    }

    private var chosen: FeedbackRating? { message.feedback?.rating }

    private func thumbTitle(_ rating: FeedbackRating) -> String {
        switch (rating, chosen == rating) {
        case (.up, false): "Good reply"
        case (.down, false): "Bad reply"
        case (.up, true): "Remove thumbs up"
        case (.down, true): "Remove thumbs down"
        }
    }

    private func thumbSymbol(_ rating: FeedbackRating) -> String {
        "hand.thumbs\(rating == .up ? "up" : "down")\(chosen == rating ? ".fill" : "")"
    }

    private func thumb(_ rating: FeedbackRating) {
        onFeedback?(chosen == rating ? nil : rating)
    }

    /// When it was said and what can be done about it, in one quiet line under the message. On
    /// a Mac it shows under the pointer; a phone has no pointer and keeps the actions in the
    /// long-press menu, as Messages does.
    @ViewBuilder private var meta: some View {
        HStack(spacing: 2) {
            if let chosen {
                Image(systemName: thumbSymbol(chosen))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .accessibilityLabel(chosen == .up ? "You rated this good" : "You rated this bad")
            }
            HStack(spacing: 2) {
                Text(shortTime(message.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                #if os(macOS)
                actions
                #endif
            }
            #if os(macOS)
            // Hidden rather than removed, so a row does not change height under the pointer.
            .opacity(hovering ? 1 : 0)
            #endif
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if !message.content.isEmpty {
                action(copied ? "Copied" : "Copy", copied ? "checkmark" : "doc.on.doc") { copy() }
            }
            if canForward { action("Send to…", "arrowshape.turn.up.right") { forward() } }
            if let onRetry { action("Retry", "arrow.clockwise", onRetry) }
            if let onRestore { action("Restore to this message", "arrow.uturn.backward", onRestore) }
            if onFeedback != nil {
                ForEach([FeedbackRating.up, .down], id: \.self) { rating in
                    action(thumbTitle(rating), thumbSymbol(rating)) { thumb(rating) }
                }
            }
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

    private var ownerBubble: some View {
        Group {
            if let answers = interviewAnswers(message.content) {
                InterviewAnswers(answers: answers)
            } else {
                Text(message.content).textSelection(.enabled)
            }
        }
        .foregroundStyle(bubbleText)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(bubble, in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20))
        .padding(.leading, 48)
    }

    private var reply: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let speaker, let sender = message.sender {
                HStack(spacing: 6) {
                    // Still: a row is history, and a live avatar per row is a canvas per row per
                    // frame. The pill above carries the agent's real state.
                    BloubView(state: .idle, identity: looks[sender], size: 18, frozenAt: 0)
                    Text(speaker)
                }
                .font(.subheadline.weight(.semibold))
                .fontDesign(.rounded)
            }
            if !message.content.isEmpty {
                ReplyBubbles(
                    chunks: bubbleChunks(message.content),
                    enterFrom: enterFrom,
                    files: message.role == .assistant ? message.sender.map { FileSource(session: session, agent: $0) } : nil,
                    fill: replyBubble,
                    link: replyLink,
                    actions: menuActions
                )
            }
        }
    }

    private var menuActions: [ReplyAction] {
        var out = [ReplyAction(title: "Copy Reply", symbol: "doc.on.doc") { copyToPasteboard(message.content) }]
        if canForward { out.append(ReplyAction(title: "Send to…", symbol: "arrowshape.turn.up.right") { forward() }) }
        if let onRetry { out.append(ReplyAction(title: "Retry", symbol: "arrow.clockwise", perform: onRetry)) }
        if let onRestore { out.append(ReplyAction(title: "Restore to this message", symbol: "arrow.uturn.backward", perform: onRestore)) }
        if onFeedback != nil {
            for rating in [FeedbackRating.up, .down] {
                out.append(ReplyAction(title: thumbTitle(rating), symbol: thumbSymbol(rating)) { thumb(rating) })
            }
        }
        return out
    }
}

struct ReplyBubbles: View {
    let chunks: [String]
    /// From this bubble on, they come in one at a time with the typing bubble between them.
    var enterFrom: Int? = nil
    var files: FileSource?
    let fill: Color
    let link: Color
    var actions: [ReplyAction] = []

    @State private var revealed: Int?
    @State private var played = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(chunks: [String], enterFrom: Int? = nil, files: FileSource? = nil, fill: Color, link: Color, actions: [ReplyAction] = []) {
        self.chunks = chunks
        self.enterFrom = enterFrom
        self.files = files
        self.fill = fill
        self.link = link
        self.actions = actions
        // Set before the first frame: from `.task` the first bubble is already drawn by the time it runs.
        _revealed = State(initialValue: enterFrom)
    }

    private var shown: Int { min(revealed ?? chunks.count, chunks.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(replySegments(Array(chunks.prefix(shown))).enumerated()), id: \.offset) { _, segment in
                Group {
                    switch segment {
                    case .text(let bubbles):
                        ReplyText(chunks: bubbles, files: files, fill: fill, link: link, actions: actions)
                    case .file(let path):
                        if let files {
                            FileCard(source: files, path: path)
                        } else {
                            Text(path).font(.callout.monospaced())
                        }
                    }
                }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
            }
            if shown < chunks.count {
                TypingBubble(fill: fill).padding(.top, 5)
            }
        }
        .modifier(FileLinkOpening(files: files))
        .animation(.spring(duration: 0.4, bounce: 0.3), value: shown)
        .task {
            guard let start = enterFrom, !played, start < chunks.count else { return }
            played = true
            revealed = start
            for chunk in chunks.dropFirst(start) {
                if revealed != start {
                    // ponytail: pause scales with length, a real typing speed model if it reads wrong
                    try? await Task.sleep(for: .seconds(0.35 + min(Double(chunk.count) / 300, 0.9)))
                }
                revealed = (revealed ?? 0) + 1
            }
            revealed = nil
        }
    }
}

struct TypingBubble: View {
    let fill: Color
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { dot in
                    let wave = reduceMotion ? 0 : max(0, sin((time * 2 * .pi / 1.2) - Double(dot) * 0.7))
                    Circle()
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.5 * wave)
                        .offset(y: -3 * wave)
                }
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(fill, in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6, bottomTrailingRadius: 20, topTrailingRadius: 20))
        .scaleEffect(appeared || reduceMotion ? 1 : 0.6, anchor: .bottomLeading)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.spring(duration: 0.4, bounce: 0.3)) { appeared = true } }
        .accessibilityLabel("Writing")
    }
}

/// Fixed when the bubble is made: the row is redrawn with its arrival cleared while the spring still runs.
struct SendEntrance: ViewModifier {
    @State private var landed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(active: Bool) { _landed = State(initialValue: !active) }

    func body(content: Content) -> some View {
        content
            .scaleEffect(landed || reduceMotion ? 1 : 0.6, anchor: .bottomTrailing)
            .offset(y: landed || reduceMotion ? 0 : 24)
            .opacity(landed ? 1 : 0)
            .onAppear {
                guard !landed else { return }
                withAnimation(.spring(duration: 0.4, bounce: 0.3)) { landed = true }
            }
    }
}

/// Not observed: a row reads its entry once, and taking it out must not redraw the chat.
final class Arrivals {
    var from: [Int: Int] = [:]
}

/// A stretch of tool traffic folded into one chip, screenshots included. Open, the steps hang
/// off a rail under it, the way a build log sits under its target.
struct ToolRun: View, Equatable {
    let run: [ToolStep]
    /// Who did it, in a thread where several agents work. An agent's own thread names nobody.
    var by: String? = nil

    @State private var open = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.run == rhs.run && lhs.by == rhs.by
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(run) { step in
                    if step.message.role == .assistant, !step.message.content.isEmpty {
                        MarkdownText(content: step.message.content)
                            .equatable()
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                    ToolRow(message: step.message, name: step.name, orphaned: step.orphaned)
                }
            }
            .padding(.leading, 20)
            .padding(.top, 6)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.quaternary)
                    .frame(width: 2)
                    .padding(.leading, 9)
                    .padding(.vertical, 6)
            }
        } label: {
            let summary = toolSummary(run.map(\.message))
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption2)
                Text(by.map { "\($0): \(summary)" } ?? summary)
                    .font(.canvas(13, .footnote))
                    .lineLimit(1)
            }
        }
        .disclosureGroupStyle(WholeRowDisclosure(chip: true))
    }
}

/// A tool line the reader just opened or closed grows downwards, under the pointer, instead of
/// being pushed up by the bottom anchor. Released on its own: an anchor that changes in the same
/// update as new rows is applied to them too late. An object rather than a closure in the
/// environment: a closure is never equal to the last one, so every line reading it redrew with
/// each change to the chat.
@Observable
final class ScrollHold {
    private(set) var holding = false

    func hold() {
        holding = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            holding = false
        }
    }
}

extension EnvironmentValues {
    @Entry var holdScroll: ScrollHold?
    @Entry var arrivals: Arrivals?
    /// The message a file card sits in, so forwarding the file brings the message along.
    @Entry var forwardedMessage: Int?
}

/// A macOS `DisclosureGroup` answers only its chevron; here the whole line is the control. As a
/// chip, the line is a capsule that reads as one thing folded away; bare, it is a row in a list
/// of steps.
struct WholeRowDisclosure: DisclosureGroupStyle {
    var chip = false

    func makeBody(configuration: Configuration) -> some View {
        Line(configuration: configuration, chip: chip)
    }

    private struct Line: View {
        let configuration: Configuration
        let chip: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.holdScroll) private var holdScroll

        #if os(macOS)
        private var card: Bool { chip }
        #else
        private let card = false
        #endif

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    holdScroll?.hold()
                    withAnimation(reduceMotion ? nil : .snappy) { configuration.isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        if !chip { chevron }
                        configuration.label
                        if card { Spacer(minLength: 0) }
                        if chip { chevron }
                        if !chip { Spacer(minLength: 0) }
                    }
                    .foregroundStyle(card ? AnyShapeStyle(Theme.secondary) : AnyShapeStyle(Color.secondary))
                    .fontWeight(card ? .semibold : nil)
                    .padding(.horizontal, card ? 14 : chip ? 12 : 0)
                    .padding(.vertical, card ? 10 : chip ? 6 : 0)
                    .background(chip && !card ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .capsule)
                    #if os(iOS)
                    .frame(minHeight: chip ? 44 : 36)
                    #else
                    .frame(minHeight: 24)
                    #endif
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")

                if configuration.isExpanded {
                    configuration.content
                        .padding(.horizontal, card ? 14 : 0)
                        .padding(.bottom, card ? 10 : 0)
                }
            }
            .background {
                if card {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Theme.card)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                }
            }
            .frame(maxWidth: card ? 640 : nil, alignment: .leading)
        }

        private var chevron: some View {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
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
                    .padding(10)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 10))
                    .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: message.role == .tool ? "arrow.turn.down.left" : "wrench.adjustable")
                        .frame(width: 14)
                    Text(title).monospaced()
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
    }
}

/// The reply as the model is still writing it, in the same column its finished form will take.
/// Gone the moment the stored message arrives.
struct LiveRow: View {
    let reply: LiveReply
    let agent: String
    let bubble: Color
    let link: Color
    @Binding var thinkingOpen: Bool
    var onRetry: (_ useBackup: Bool) async -> Void = { _ in }

    /// The paragraph still being written is held back, as a chat app shows a message only once it is sent.
    private var sent: [String] { Array(bubbleChunks(reply.text).dropLast()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !sent.isEmpty {
                ReplyBubbles(chunks: sent, enterFrom: 0, fill: bubble, link: link)
                    .zIndex(1)
            }
            if let retry = reply.retry {
                RetryCard(retry: retry, onRetry: onRetry)
            } else {
                Button {
                    guard !reply.reasoning.isEmpty else { return }
                    withAnimation(.snappy(duration: 0.25)) { thinkingOpen.toggle() }
                } label: {
                    TypingBubble(fill: bubble)
                }
                .buttonStyle(.plain)
                .help(thinkingOpen ? "Hide thinking" : "Show thinking")
                .accessibilityLabel("\(agent) is writing")
                .accessibilityHint(reply.reasoning.isEmpty ? "" : "Shows what it is thinking")
            }
            if thinkingOpen, !reply.reasoning.isEmpty {
                // The tail only, at a fixed height, so the thinking never pushes the thread around.
                Text(reply.reasoning)
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(5, reservesSpace: true)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubble.opacity(0.5), in: .rect(cornerRadius: 14))
                    .padding(.trailing, 48)
                    .transition(.scale(scale: 0.9, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.3), value: sent.count)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A browser the watchdog restarted once and that still does not answer: the owner's three ways out.
struct BrowserHungCard: View {
    let agent: String
    let onScreen: () -> Void
    let onRestart: (_ desktop: Bool) async -> Void

    @State private var acting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text("Needs you · browser stuck")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.needsYou)
            Text("\(agent)'s browser stopped answering")
                .font(.subheadline.weight(.semibold))
            Text("It was restarted once on its own and still does not answer.")
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { choices }
                VStack(alignment: .leading, spacing: 8) { choices }
            }
            .controlSize(.small)
            .disabled(acting)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var choices: some View {
        Button("Restart browser") { restart(desktop: false) }
            .buttonStyle(.pill(.primary))
        Button("Restart desktop and retry") { restart(desktop: true) }
            .buttonStyle(.pill(.secondary))
        Button("Look at the screen", action: onScreen)
            .buttonStyle(.pill(.secondary))
    }

    private func restart(desktop: Bool) {
        acting = true
        Task {
            await onRestart(desktop)
            acting = false
        }
    }
}

/// The agent asked the owner to take its screen: why, and the one way to do it.
struct HandOverCard: View {
    let agent: String
    let reason: String
    let onTake: () async -> Void

    @State private var acting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised")
                Text("Needs you · hands")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.needsYou)
            Text("\(agent) asks you to take the screen")
                .font(.subheadline.weight(.semibold))
            Text(reason)
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
            Button("Take the screen") {
                acting = true
                Task {
                    await onTake()
                    acting = false
                }
            }
            .buttonStyle(.pill(.primary))
            .controlSize(.small)
            .disabled(acting)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The model call that failed and is about to be asked again: the canvas "Retrying" state, the
/// attempt, and the owner's two ways to not wait for it.
struct RetryCard: View {
    let retry: RetryState
    let onRetry: (_ useBackup: Bool) async -> Void

    @State private var acting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                Text("Retrying")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.retrying)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.headline(retry, now: context.date))
                    .font(.subheadline.weight(.semibold))
            }
            Text(retry.error)
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Button("Retry now") { act(useBackup: false) }
                    .buttonStyle(.pill(.primary))
                if let backup = retry.backup {
                    Button("Use backup model") { act(useBackup: true) }
                        .buttonStyle(.pill(.secondary))
                        .help("Switch this turn to \(backup)")
                        .accessibilityHint("Switches this turn to \(backup)")
                }
            }
            .controlSize(.small)
            .disabled(acting)
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline) }
    }

    /// "Main is busy. Trying again in 12 s, attempt 2 of 5", or "… again now" once the wait is over.
    static func headline(_ retry: RetryState, now: Date) -> String {
        let seconds = Int((Double(retry.retryAt) / 1000 - now.timeIntervalSince1970).rounded(.up))
        let when = seconds > 0 ? "in \(seconds) s" : "now"
        return "\(retry.model) is busy. Trying again \(when), attempt \(retry.attempt) of \(retry.of)"
    }

    private func act(useBackup: Bool) {
        acting = true
        Task {
            await onRetry(useBackup)
            acting = false
        }
    }
}

private extension View {
    func actionCard(_ agent: Color) -> some View {
        background(Theme.card, in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(agent.opacity(0.45), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 6)
    }

    #if os(macOS)
    /// Main's white over the chat: the composer and its chips. `blur` is the canvas's CSS blur,
    /// which SwiftUI's radius halves.
    func floatingCard(radius: CGFloat, fill: Double = 0.86, shadow: Double = 0.08, blur: CGFloat = 28, y: CGFloat = 8) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.card.opacity(fill))
                .strokeBorder(Theme.card.opacity(0.95), lineWidth: 1)
                .shadow(color: .black.opacity(shadow), radius: blur / 2, y: y)
        }
    }
    #endif
}
