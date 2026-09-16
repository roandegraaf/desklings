import SwiftUI

/// One agent's desktop connection: the picture, and the one ordered pipe input goes down. Kept
/// apart from `DesktopView` so the inspector's thumbnail and the full view it opens can share it:
/// Xvnc counts a viewer per socket, and two of them on one desktop is what this prevents.
@Observable final class DesktopLink {
    private(set) var screen: CGImage?
    private(set) var failure: String?

    @ObservationIgnored private var input: AsyncStream<@Sendable (RfbClient) async -> Void>.Continuation?
    /// Put back on every connect, so a socket that is replaced keeps the hold the viewer asked for.
    @ObservationIgnored private var holding = false

    func hold(_ wanted: Bool) {
        holding = wanted
        send { await $0.hold(wanted) }
    }

    func send(_ call: @escaping @Sendable (RfbClient) async -> Void) {
        input?.yield(call)
    }

    /// The client runs as a child of this task rather than beside it, so cancelling the caller
    /// cancels it whatever the frame stream happens to be doing: cancellation reaches `run()`,
    /// which closes the socket and finishes the stream, which is what ends the loop below.
    func run(session: Session, agent: String) async {
        guard let socket = try? session.client?.vnc(agent: agent) else {
            failure = SchermesError.badURL.errorDescription
            return
        }
        let client = RfbClient(transport: WebSocketTransport(socket))
        let (calls, feed) = AsyncStream<@Sendable (RfbClient) async -> Void>
            .makeStream(bufferingPolicy: .unbounded)
        input = feed
        defer { input = nil }

        let hold = holding
        feed.yield { await $0.hold(hold) }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            // One consumer, spending the calls in the order the hand made them. A button down and
            // the button up that ends it are not interchangeable, and separate tasks onto an actor
            // have no order at all.
            group.addTask { for await call in calls { await call(client) } }

            for await event in client.events {
                switch event {
                case .frame(let image):
                    screen = image
                    failure = nil
                case .failed(let why):
                    failure = why
                }
            }
            feed.finish()
        }
        // Closed by the last viewer leaving rather than dropped: the next one to open this
        // desktop should see it connecting, not a minutes-old frame that reads as live.
        if Task.isCancelled {
            screen = nil
            failure = nil
        }
    }
}

/// One `DesktopLink` per agent for the whole app, however many views show that desktop. On a Mac
/// the inspector's thumbnail and the desktop's own window are in different scenes and still read
/// one socket.
@Observable final class Desktops {
    // Links are never removed: a view that fetched one just before the last viewer left would
    // otherwise keep drawing a link nothing runs any more.
    @ObservationIgnored private var links: [String: DesktopLink] = [:]
    @ObservationIgnored private var viewers: [String: Int] = [:]
    @ObservationIgnored private var runs: [String: Task<Void, Never>] = [:]

    func link(_ agent: String) -> DesktopLink {
        if let link = links[agent] { return link }
        let link = DesktopLink()
        links[agent] = link
        return link
    }

    func watch(_ agent: String, session: Session) async {
        let link = link(agent)
        viewers[agent, default: 0] += 1
        if runs[agent] == nil {
            runs[agent] = Task {
                while !Task.isCancelled {
                    await link.run(session: session, agent: agent)
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        viewers[agent, default: 1] -= 1
        guard viewers[agent] == 0 else { return }
        viewers[agent] = nil
        runs.removeValue(forKey: agent)?.cancel()
    }
}

#if os(macOS)
/// Handed a name rather than an `Agent`, which would freeze the state dot and, as the window's
/// identity, open a second window whenever the state changed.
struct DesktopWindow: View {
    let session: Session
    let name: String

    @State private var agent: Agent?
    @State private var gone = false

    var body: some View {
        Group {
            if let agent {
                DesktopView(session: session, agent: agent)
            } else if gone {
                ContentUnavailableView("No screen", systemImage: "display", description: Text("This agent no longer exists."))
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .windowToolbarFullScreenVisibility(.onHover)
        .task {
            while !Task.isCancelled {
                if let rows = try? await session.run({ try await $0.agents() }) {
                    agent = rows.first { $0.name == name }
                    gone = agent == nil
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
#endif

/// One agent's live screen, and the owner's hands on it when they ask for them. Full-bleed dark
/// with the picture scaled to fit and letterboxed. On a Mac it fills its own window, with the
/// agent and taking or returning control in the toolbar; elsewhere it covers the screen, with the
/// way back and the agent at the top left and control at the top right.
///
/// Input is sent only while the daemon says this viewer holds the desktop. The proxy filters
/// nothing, so `viewOnly` is the rule and an unknown answer is not a yes.
struct DesktopView: View {
    let session: Session
    let agent: Agent

    @State private var trouble: String?
    @State private var held: Bool?
    @State private var typing = false
    @State private var box = CGSize.zero

    @Environment(AgentLooks.self) private var looks
    @Environment(Desktops.self) private var desktops
    @Environment(\.dismiss) private var dismiss

    private var link: DesktopLink { desktops.link(agent.name) }
    private var holding: Bool { !viewOnly(held) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            picture
                // Only while the desktop is this viewer's: with no hold there is nothing for a
                // pointer or a key to do, and nothing over the picture to catch one.
                .overlay { if holding { hands } }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { box = $0 }
        }
        #if os(macOS)
        // In the window's toolbar, which sits outside the content view: on macOS a click on a
        // SwiftUI control drawn above an `NSView` reaches the view underneath as well, so chrome
        // over the desktop landed every press of Return control on the agent's screen too.
        .navigationTitle(agent.title)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) { identity.padding(.horizontal, 8) }
            ToolbarItem { control.labelStyle(.titleAndIcon) }
        }
        #else
        .safeAreaInset(edge: .top) { bar }
        #endif
        .overlay(alignment: .bottom) { complaint }
        .preferredColorScheme(.dark)
        // Leaving cancels this, and the last view of this desktop to leave closes the socket.
        .task(id: agent.name) { await desktops.watch(agent.name, session: session) }
        .task(id: agent.name) { await follow() }
        .onChange(of: held) {
            let now = holding
            if !now { typing = false }
            link.hold(now)
        }
        // A borrowed connection outlives this view, and nothing may be able to write to the
        // desktop once the hands that would have are gone.
        .onDisappear { link.hold(false) }
    }

    private var picture: some View {
        ZStack {
            if let screen = link.screen {
                Image(decorative: screen, scale: 1, orientation: .up)
                    .interpolation(.medium)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .accessibilityLabel("\(agent.title)'s screen")
            } else {
                VStack(spacing: 12) {
                    if link.failure == nil { ProgressView().controlSize(.large) }
                    Text(link.failure ?? "Connecting to \(agent.title)'s desktop…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        // The box the letterbox is measured against, so the transform and the picture cannot
        // disagree about where the bars are.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var hands: some View {
        #if os(macOS)
        DesktopInput(send: relay)
        #else
        DesktopInput(send: relay, typing: typing)
        #endif
    }

    // MARK: - Chrome

    private var identity: some View {
        HStack(spacing: 7) {
            BloubView(state: agent.state.bloub, identity: looks[agent.name], size: 22)
            Text(agent.title).font(.headline)
            StateDot(state: agent.state)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.title), \(agent.state.label)")
    }

    private var control: some View {
        Button(
            holding ? returnTitle : "Take control",
            systemImage: holding ? "hand.raised.fill" : "hand.raised"
        ) { take(!holding) }
            .lineLimit(1)
            .accessibilityLabel(holding ? "Return control" : "Take control")
            // Unknown ownership is not a no: until the daemon has answered there is nothing
            // to take or return, exactly as the web UI has it.
            .disabled(held == nil)
    }

    #if os(macOS)
    private let returnTitle = "Return control"
    #else
    // The full phrase plus the keyboard button is wider than an iPhone, and the label wrapped
    // onto two lines.
    private let returnTitle = "Return"

    private var bar: some View {
        HStack(spacing: 10) {
            Button("Back", systemImage: "chevron.left") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                // Escape belongs to the desktop while the desktop is this viewer's: a shortcut
                // here is consulted before the key shim ever sees the press.
                .keyboardShortcut(holding ? nil : KeyboardShortcut(.escape, modifiers: []))

            identity
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)

            Spacer(minLength: 12)

            // The software keyboard is raised deliberately: it covers half the desktop, and most
            // of what is done on one is done with the pointer.
            if holding {
                Button(
                    typing ? "Hide keyboard" : "Keyboard",
                    systemImage: typing ? "keyboard.chevron.compact.down" : "keyboard"
                ) { typing.toggle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            }

            control.buttonStyle(.glass)
        }
        .padding(16)
    }
    #endif

    /// A refusal from the control routes has nowhere else to go, and it is the one error here the
    /// owner can do something about. The connection's own failure is shown in the middle while
    /// there is no picture, so only the control half is repeated down here.
    @ViewBuilder private var complaint: some View {
        if let why = trouble ?? (link.screen == nil ? nil : link.failure) {
            Text(why)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .padding(20)
        }
    }

    // MARK: - Control

    private func follow() async {
        while !Task.isCancelled {
            // A poll that failed says nothing about who holds the desktop, so the last answer
            // stands rather than being replaced by a guess. The web UI makes the same call.
            if let state = try? await session.run({ try await $0.control(agent: agent.name) }) {
                held = state.held
            }
            try? await Task.sleep(for: .seconds(4))
        }
    }

    private func take(_ next: Bool) {
        Task {
            do {
                let state = try await session.run {
                    try await $0.setControl(agent: agent.name, held: next)
                }
                held = state.held
                trouble = nil
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
        }
    }

    // MARK: - Input

    /// The letterbox transform, and the only path from a hand to the client.
    private func relay(_ event: DesktopInputEvent) {
        switch event {
        case .key(let keysym, let down):
            link.send { await $0.key(keysym, down: down) }

        case .move(let point):
            guard let (x, y) = landing(point) else { return }
            link.send { await $0.move(x: x, y: y) }

        case .button(let button, let down, let point):
            guard let (x, y) = landing(point) else {
                // A release that lands on the bars is still a release: dropping it would leave the
                // button down on a desktop this viewer may be about to give back.
                if !down { link.send { await $0.release(button) } }
                return
            }
            link.send { await $0.button(button, down: down, x: x, y: y) }

        case .wheel(let direction, let point):
            guard let (x, y) = landing(point) else { return }
            link.send { await $0.wheel(direction, x: x, y: y) }
        }
    }

    private func landing(_ point: CGPoint) -> (x: Int, y: Int)? {
        guard let screen = link.screen else { return nil }
        return framebufferPoint(
            point,
            view: box,
            screen: CGSize(width: screen.width, height: screen.height)
        )
    }
}
