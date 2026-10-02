import SwiftUI

extension Approval {
    /// What the agent asks, after its name: "wants to delete its thread with Juno".
    func asks(_ title: (String) -> String) -> String {
        switch kind {
        case .agent:
            return target == agent ? "wants to delete itself" : "wants to delete \(title(target))"
        case .conversation:
            // Its own name is not news to the owner; who else is in the thread is.
            let others = participants.filter { $0 != agent }.map(title)
            guard !others.isEmpty else { return "wants to delete its own thread" }
            return "wants to delete its thread with \(others.formatted(.list(type: .and)))"
        case .action:
            var text = "wants to " + (Self.categoryWords[category] ?? category)
            if !target.isEmpty { text += ": \(target)" }
            if let amount { text += " (\(amount))" }
            if let origin { text += " at \(origin)" }
            return text
        }
    }

    var noWord: String { kind == .action ? "Don't" : "Keep it" }
    /// Passwords and security stay the owner's: their yes means they will do it themselves.
    var yesWord: String {
        kind != .action ? "Delete it" : category == "passwords_security" ? "I'll do it" : "Approve"
    }
    /// What "Always allow" names: the site, or for a message the recipient.
    var alwaysWhat: String { origin ?? target }
    /// Only a deletion is final; an action's yes lets the agent go ahead.
    var yesRole: ButtonRole? { kind == .action ? nil : .destructive }

    private static let categoryWords = [
        "browse": "browse",
        "run_commands": "run a command",
        "write_files": "write files",
        "delete_files": "delete files",
        "send_messages": "send a message",
        "spend_money": "spend money",
        "install_software": "install software",
        "share_outside": "share something outside",
        "passwords_security": "change a password or security setting",
    ]
}

extension NeedsYouAction {
    var isQuiet: Bool { self == .deny || self == .open || self == .screen }
    /// Quiet first, then Always allow, then the go-ahead, as the canvas card lays them out.
    var order: Int { isQuiet ? 0 : self == .always ? 1 : self == .fill ? 3 : 2 }
}

extension NeedsYouItem {
    /// The item's state, as a symbol and a word like every other state.
    var presentation: (symbol: String, word: String) {
        switch kind {
        case .approval: ("bell", approval?.kind == .action ? "Needs you · asks first" : "Needs you · delete")
        case .question: ("bell", "Needs you · question")
        case .failure: ("exclamationmark.triangle", "Failed")
        case .providerAuth: ("key", "Needs you · key refused")
        case .browserHung: ("exclamationmark.triangle", "Needs you · browser stuck")
        case .handOver: ("hand.raised", "Needs you · hands")
        case .form: ("list.bullet.rectangle", "Needs you · form")
        case .goal: ("flag", "Needs you · goal")
        case .other: ("bell", "Needs you")
        }
    }
}

/// Where a retry of a failed turn cuts: the row after the message the failed turn answered, as
/// the chat's own Retry does it. Nil when that message isn't in `loaded`, or when the owner has
/// written since, since a retry would take their words with it and the chat asks first for that.
func retryStart(_ loaded: [Message], failure: Int) -> Int? {
    guard let from = ChatRows(loaded, mark: 0).retryFrom[failure],
          !loaded.contains(where: { $0.isOwner && $0.id >= from })
    else { return nil }
    return from
}

/// The owner's dashboard: what waits on them first and loudest, then the agents right now and
/// what they did while the owner was away. On a wide window the agents sit in a column beside it.
struct HomePage: View {
    let session: Session
    let items: [NeedsYouItem]
    let agents: [Agent]
    let wide: Bool
    let onAct: (NeedsYouItem, NeedsYouAction) async -> Void

    @State private var twoColumns = false

    private var titles: [String: String] { Schermes.titles(agents) }

    var body: some View {
        ScrollView {
            if wide {
                // A width check rather than `ViewThatFits`, whose measuring pass clipped wrapped text on the Mac.
                Group {
                    if twoColumns {
                        HStack(alignment: .top, spacing: 24) {
                            VStack(spacing: 14) { header; waiting; lastNight }
                            rightNow.frame(width: 340)
                        }
                    } else {
                        VStack(spacing: 14) { header; waiting; rightNow; lastNight }
                    }
                }
                .padding(.vertical, 32)
                .padding(.horizontal, 36)
            } else {
                VStack(spacing: 12) { waiting; lastNight }.padding(16)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 860 } action: { twoColumns = $0 }
        .animation(.snappy, value: items.map(\.id))
        .background(Theme.ground)
        .navigationTitle("Home")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // Beside the back button, as on the canvas: a `.largeTitle` item is ignored in the split
        // view's detail column.
        .toolbar(removing: wide ? nil : .title)
        .toolbar {
            if !wide {
                ToolbarItem(placement: .topBarLeading) {
                    Text("Home")
                        .font(.pageTitle)
                        .fixedSize()
                        .accessibilityAddTraits(.isHeader)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Home")
                .font(.pageTitle)
                .tracking(-0.7)
            Text(summary)
                .font(.canvas(15, .subheadline, weight: items.isEmpty ? .regular : .semibold))
                .foregroundStyle(items.isEmpty ? Theme.muted : Theme.needsYou)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: String {
        let working = agents.filter(\.state.busy).count
        let running = working == 0 ? "No agent is working right now."
            : working == 1 ? "One agent is working right now."
            : "\(working) agents are working right now."
        switch items.count {
        case 0: return "Nothing needs you. \(running)"
        case 1: return "One thing is waiting on you."
        default: return "\(items.count) things are waiting on you."
        }
    }

    /// Only there when something waits, on the Needs you tint so it reads before anything else.
    @ViewBuilder private var waiting: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(items.count == 1 ? "Needs you" : "Needs you · \(items.count)")
                } icon: {
                    Image(systemName: "bell.fill")
                }
                .font(.canvas(15, .headline, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.needsYou)
                .padding(.horizontal, 4)
                ForEach(items) { item in
                    NeedsYouCard(item: item, agent: agents.first { $0.name == item.agent }, titles: titles, onAct: onAct)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.needsYouSoft, in: .rect(cornerRadius: 26))
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }

    /// Who is working first, then every other lead agent at rest; a worker only while it works.
    private var rightNow: some View {
        Panel(title: "Right now") {
            let shown = agents.filter(\.state.busy) + agents.filter { !$0.state.busy && $0.parentId == nil }
            if shown.isEmpty {
                Text("No agents yet.")
                    .font(.canvas(13, .footnote))
                    .foregroundStyle(Theme.muted)
            }
            ForEach(shown) { agent in
                AgentStateRow(agent: agent, waiting: items.contains { $0.agent == agent.name && $0.kind != .failure })
            }
        }
    }

    private var lastNight: some View {
        Panel(title: "Last night") {
            LastNight(session: session, agents: agents, approvals: items.compactMap(\.approval), titles: titles)
        }
    }
}

struct AgentStateRow: View {
    let agent: Agent
    var waiting = false
    var size: CGFloat = 24

    @Environment(AgentLooks.self) private var looks

    var body: some View {
        HStack(spacing: 10) {
            BloubView(state: agent.state.bloub, identity: looks[agent.name], size: size)
                .busyHalo(agent.state.busy, color: looks[agent.name].color)
            Text(agent.title)
                .font(.canvas(13, .footnote, weight: .bold))
                .foregroundStyle(Theme.ink)
            if waiting {
                Label("Needs you", systemImage: "bell")
                    .font(.canvas(13, .footnote, weight: .semibold))
                    .foregroundStyle(Theme.needsYou)
            } else {
                StateLine(state: agent.state, identity: looks[agent.name], font: .canvas(13, .footnote))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.canvas(17, .headline, weight: .bold, design: .rounded))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: .rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.hairline) }
    }
}

struct NeedsYouCard: View {
    let item: NeedsYouItem
    let agent: Agent?
    let titles: [String: String]
    /// The menu bar's one-line row on the Needs you fill, with small answers.
    var compact = false
    let onAct: (NeedsYouItem, NeedsYouAction) async -> Void

    @Environment(AgentLooks.self) private var looks
    @Environment(\.colorScheme) private var scheme
    @State private var acting = false

    private func title(_ name: String) -> String { titles[name] ?? name }

    private var headline: String {
        if let approval = item.approval { return "\(title(item.agent)) \(approval.asks(title))" }
        return item.title
    }

    /// The approval's reason; a failure's error. A question's own words are the headline.
    private var detail: String? { item.approval?.reason ?? item.detail }

    #if os(macOS)
    private static let (bloub, gap, inset, fills): (CGFloat, CGFloat, CGFloat, Bool) = (40, 12, 16, false)
    #else
    /// The iPhone card's answers share its width; the Mac's sit at the trailing edge.
    private static let (bloub, gap, inset, fills): (CGFloat, CGFloat, CGFloat, Bool) = (34, 10, 14, true)
    #endif

    var body: some View {
        if compact { row } else { card }
    }

    private var row: some View {
        let face = HStack(spacing: 10) {
            BloubView(state: .notify, identity: looks[item.agent], size: 26)
            Text("\(Text(title(item.agent)).bold()) \(item.approval?.asks(title) ?? item.title)")
                .font(.canvas(13, .footnote))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
        }
        let answers = HStack(spacing: 6) { actionButtons }
            .controlSize(.small)
            .disabled(acting)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                face
                Spacer(minLength: 0)
                answers
            }
            VStack(alignment: .leading, spacing: 8) {
                face
                answers.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(8)
        .background(Theme.needsYouSoft, in: .rect(cornerRadius: 12))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            HStack(spacing: Self.gap) {
                BloubView(state: .notify, identity: looks[item.agent], size: Self.bloub)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.canvas(15, .subheadline, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(4)
                    subline
                }
                Spacer(minLength: 0)
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.canvas(13, .footnote))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(4)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(detailFill, in: .rect(cornerRadius: 12))
            }
            buttons
                .controlSize(.regular)
                .disabled(acting)
        }
        .padding(Self.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.hairline) }
    }

    /// An approval's context sits on the agent's soft colour; anything else on the ground.
    private var detailFill: AnyShapeStyle {
        item.approval == nil
            ? AnyShapeStyle(Theme.ground)
            : AnyShapeStyle(looks[item.agent].palette(dark: scheme == .dark).soft.color)
    }

    /// Who, the item's state in its colour, and when.
    private var subline: some View {
        let word = Text(item.presentation.word)
            .foregroundStyle(item.kind == .failure ? Theme.failed : Theme.needsYou)
            .fontWeight(.semibold)
        return Text("\(title(item.agent)) · \(word) · \(shortTime(item.createdAt))")
            .font(.canvas(13, .caption))
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
    }

    /// In a row when they fit, stacked on a narrow screen: a hung browser has three long ways out.
    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if !Self.fills { Spacer(minLength: 0) }
                actionButtons
            }
            VStack(alignment: .trailing, spacing: 8) { actionButtons }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func pill(
        _ title: String, _ kind: PillButtonStyle.Kind, _ action: NeedsYouAction, role: ButtonRole? = nil
    ) -> some View {
        Button(role: role) { act(action) } label: {
            Text(title).frame(maxWidth: Self.fills && !compact ? .infinity : nil)
        }
        .buttonStyle(.pill(kind))
    }

    @ViewBuilder private var actionButtons: some View {
        let color = looks[item.agent].color
        Group {
            // The quiet answer first and the go-ahead last, whichever order the daemon lists them in.
            ForEach(item.actions.sorted { $0.order < $1.order }, id: \.self) { action in
                switch action {
                case .deny:
                    pill(item.approval?.noWord ?? "Don't", .secondary, .deny)
                case .always:
                    pill("Always allow \(item.approval?.alwaysWhat ?? "")", .outline(color), .always)
                case .approve:
                    pill(
                        item.actions.contains(.always) ? "Approve once" : item.approval?.yesWord ?? "Approve",
                        item.approval?.yesRole == nil ? .agent(color) : .destructive,
                        .approve,
                        role: item.approval?.yesRole
                    )
                case .answer:
                    pill("Answer", .primary, .answer)
                case .retry:
                    pill("Retry", .primary, .retry)
                case .open:
                    pill(item.goalId == nil ? "Open" : "Open goal", .secondary, .open)
                case .settings:
                    pill("Open model settings", .primary, .settings)
                case .screen:
                    pill("Look at the screen", .secondary, .screen)
                case .restartDesktop:
                    pill("Restart desktop and retry", .secondary, .restartDesktop)
                case .takeScreen where item.actions.contains(.fill):
                    pill("Use the agent's screen", .secondary, .takeScreen)
                case .takeScreen:
                    pill("Take the screen", .primary, .takeScreen)
                case .fill:
                    pill("Fill in…", .primary, .fill)
                case .restartBrowser:
                    pill("Restart browser", .primary, .restartBrowser)
                case .other:
                    EmptyView()
                }
            }
            if case .other = item.kind {
                pill("Open", .secondary, .open)
            }
        }
    }

    private func act(_ action: NeedsYouAction) {
        acting = true
        Task {
            await onAct(item, action)
            acting = false
        }
    }
}

/// The top of the iPhone agent list while nothing waits: the quiet way into Home.
struct HomeStrip: View {
    let working: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "house.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 34, height: 34)
                .background(Theme.ink.opacity(0.06), in: .rect(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text("Home")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Theme.ink)
                Text(working == 0 ? "Nothing needs you" : "Nothing needs you · \(working) working")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.card, in: .rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.hairline) }
        .accessibilityElement(children: .combine)
    }
}

/// The top of the iPhone agent list: how many things wait, the first of them, and the way in.
struct NeedsYouStrip: View {
    let items: [NeedsYouItem]
    let titles: [String: String]

    @Environment(AgentLooks.self) private var looks

    private var faces: [String] {
        var seen: [String] = []
        for item in items where !seen.contains(item.agent) { seen.append(item.agent) }
        return Array(seen.prefix(3))
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: -12) {
                ForEach(faces, id: \.self) { name in
                    BloubView(state: .notify, identity: looks[name], size: 30)
                        .padding(2)
                        .background(Theme.needsYouFill, in: .circle)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(items.count == 1 ? "1 thing needs you" : "\(items.count) things need you")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Theme.ink)
                if let first = items.first {
                    Text(first.approval.map { "\(titles[first.agent] ?? first.agent) \($0.asks { titles[$0] ?? $0 })" }
                         ?? "\(titles[first.agent] ?? first.agent): \(first.title)")
                        .font(.footnote)
                        .foregroundStyle(Theme.needsYou)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.ink)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.needsYouFill, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

extension Approval {
    /// The outcome as the thread shows it. "Waiting" lasts only until Needs you's next poll lists it.
    var settled: (symbol: String, word: String, color: Token) {
        switch outcome {
        case "approved": ("checkmark.circle.fill", kind == .action ? "Approved" : "Deleted", Theme.done)
        case "declined": ("xmark.circle.fill", "Declined", Theme.failed)
        case "handed_back": ("person.crop.circle.badge.checkmark", "You do this yourself", Theme.done)
        default: ("bell", "Waiting for you", Theme.needsYou)
        }
    }
}

/// An approval request where it was asked in the thread, once it has stopped waiting.
struct ApprovalLine: View {
    let approval: Approval
    let titles: [String: String]

    private func title(_ name: String) -> String { titles[name] ?? name }

    var body: some View {
        let settled = approval.settled
        VStack(alignment: .leading, spacing: 6) {
            Text("\(Text(title(approval.agent)).bold()) \(approval.asks(title))")
                .font(.canvas(14, .subheadline))
                .foregroundStyle(Theme.ink)
            if !approval.reason.isEmpty {
                Text(approval.reason)
                    .font(.canvas(13, .footnote))
                    .foregroundStyle(Theme.secondary)
            }
            Label {
                Text([settled.word, approval.decidedAt.map(shortTime)].compactMap { $0 }.joined(separator: " · "))
            } icon: {
                Image(systemName: settled.symbol)
            }
            .font(.canvas(12, .caption, weight: .semibold))
            .foregroundStyle(settled.color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline) }
        .accessibilityElement(children: .combine)
    }
}
