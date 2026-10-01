import SwiftUI

extension GoalStepState {
    /// Like an agent's state: a symbol and a word, never colour alone.
    var presentation: (symbol: String, word: String) {
        switch self {
        case .todo: ("circle", "To do")
        case .doing: ("circle.lefthalf.filled", "Doing")
        case .done: ("checkmark.circle.fill", "Done")
        case .blocked: ("exclamationmark.octagon", "Blocked")
        case .other(let raw): ("questionmark.circle", raw.capitalized)
        }
    }
}

extension HelperKind {
    var word: String {
        switch self {
        case .worker: "Helper with its own screen"
        case .agent: "Temporary agent"
        case .other(let raw): raw.capitalized
        }
    }
}

extension BloubIdentity {
    /// A helper keeps its own shape and wears its lead's colour.
    func helping(_ lead: BloubIdentity) -> BloubIdentity {
        BloubIdentity(shape: shape, color: lead.color)
    }
}

/// Done steps over all steps, drawn like the context ring in the lead's colour.
struct GoalRing: View {
    let goal: Goal
    let identity: BloubIdentity
    var radius: CGFloat = 9

    var body: some View {
        ContextRing(percent: Int((goal.progress * 100).rounded()), identity: identity, radius: radius)
            .accessibilityLabel("\(goal.progressWords) steps done")
    }
}

/// A helper's bloub: the lead's colour inside a dashed ring of the lead's accent.
struct HelperBloub: View {
    let state: AgentState
    let name: String
    let lead: String
    var size: CGFloat = 28

    @Environment(AgentLooks.self) private var looks
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        BloubView(state: state.bloub, identity: looks[name].helping(looks[lead]), size: size)
            .overlay {
                Circle()
                    .strokeBorder(
                        looks[lead].palette(dark: scheme == .dark).accentText.color,
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
                    .padding(-3)
            }
    }
}

struct ForThisGoal: View {
    var body: some View {
        Text("For this goal")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.ink.opacity(0.06), in: .capsule)
    }
}

/// A helper nested under its lead in the sidebar.
struct HelperRow: View {
    let name: String
    let title: String
    let lead: String
    let state: AgentState

    @Environment(AgentLooks.self) private var looks

    var body: some View {
        HStack(spacing: 10) {
            HelperBloub(state: state, name: name, lead: lead)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.rounded)
                        .lineLimit(1)
                    ForThisGoal()
                }
                StateLine(state: state, identity: looks[name].helping(looks[lead]))
            }
            Spacer(minLength: 4)
        }
        .padding(.leading, 22)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The sidebar's goal row: ring, title, lead and progress.
struct GoalRow: View {
    let goal: Goal
    let leadTitle: String

    @Environment(AgentLooks.self) private var looks

    var body: some View {
        HStack(spacing: 10) {
            GoalRing(goal: goal, identity: looks[goal.lead], radius: 10.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(goal.title)
                    .font(.canvas(13, .subheadline, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(goal.isOpen ? "\(leadTitle) · \(goal.progressWords)" : "\(leadTitle) · Done")
                    .font(.canvas(12, .caption))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The iPhone home's goal card.
struct GoalCard: View {
    let goal: Goal
    let leadTitle: String

    var body: some View {
        GoalRow(goal: goal, leadTitle: leadTitle)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 170, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: 18))
            .foregroundStyle(Theme.ink)
    }
}

/// A plan step's mark: a green tick when done, the lead's colour while doing, an empty ring to do.
struct StepMark: View {
    let state: GoalStepState
    let color: BloubColorId

    #if os(macOS)
    private let size: CGFloat = 22
    #else
    private let size: CGFloat = 20
    #endif

    var body: some View {
        Group {
            switch state {
            case .done:
                Circle().fill(Theme.done)
                    .overlay { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.onInk) }
            case .doing:
                Circle().fill(color.rgb.color)
            case .blocked:
                Circle().fill(Theme.needsYou)
                    .overlay { Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.onInk) }
            case .todo, .other:
                Circle().strokeBorder(Theme.ink.opacity(0.25), lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The inspector's Goal section, after Main's aside: ring, title and progress, then the helpers
/// still on it as white rows with their state.
struct GoalSummary: View {
    let goal: Goal
    let agent: String
    let titles: [String: String]
    let onOpen: () -> Void

    @Environment(AgentLooks.self) private var looks

    private func title(_ name: String) -> String { titles[name] ?? name }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    GoalRing(goal: goal, identity: looks[goal.lead], radius: 10.5)
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(goal.title)
                            .font(.sectionTitle)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("\(goal.lead == agent ? "Goal" : "Helping \(title(goal.lead))") · \(goal.progressWords) done")
                            .font(.canvas(12, .caption))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the goal")

            ForEach(goal.temporaryHelpers) { helper in
                HStack(spacing: 10) {
                    HelperBloub(state: helper.state, name: helper.name, lead: goal.lead, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(helper.name)).font(.canvas(13, .footnote, weight: .semibold))
                        StateLine(
                            state: helper.state,
                            identity: looks[helper.name].helping(looks[goal.lead]),
                            font: .canvas(12, .caption)
                        )
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(Theme.card, in: .rect(cornerRadius: 14))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A goal: its plan, results, what the owner owes it and who is on it. A page on the Mac, pushed
/// on the iPhone.
struct GoalPage: View {
    let session: Session
    let goal: Goal
    let agents: [Agent]
    let onChanged: () async -> Void
    let onOpenAgent: (String) -> Void
    let onDeleted: () -> Void

    @Environment(AgentLooks.self) private var looks
    @Environment(\.colorScheme) private var scheme
    @State private var working = false
    @State private var trouble: String?
    @State private var keepTrouble: [String: String] = [:]
    @State private var confirmingDelete = false
    @State private var twoColumns = false

    private var names: [String: String] { titles(agents) }
    private func title(_ name: String) -> String { names[name] ?? name }
    private var accent: Color { looks[goal.lead].palette(dark: scheme == .dark).accentText.color }

    private var palette: AgentPalette { looks[goal.lead].palette(dark: scheme == .dark) }

    var body: some View {
        ScrollView {
            // Side by side when the window has room for both columns, as on the canvas's Mac board.
            // A width check rather than `ViewThatFits`, whose measuring pass clipped wrapped text.
            Group {
                if twoColumns {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 16) { header; plan; results }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 14) { nextFromYou; helpers; actions }
                            .frame(width: 340)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) { header; nextFromYou; plan; results; helpers; actions }
                }
            }
            #if os(macOS)
            .padding(.vertical, 32)
            .padding(.horizontal, 36)
            #else
            .padding(16)
            #endif
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 800 } action: { twoColumns = $0 }
        .background(palette.tint.color)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ledBy.fixedSize()
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                GoalRing(goal: goal, identity: looks[goal.lead], radius: 13)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        #endif
        .confirmationDialog("Delete this goal?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { run { try await $0.deleteGoal(id: goal.id) } then: { onDeleted() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The plan and results go, and so do the helpers nobody kept. The lead stays.")
        }
    }

    private var started: String {
        Date(timeIntervalSince1970: Double(goal.createdAt) / 1000).formatted(.dateTime.day().month(.abbreviated))
    }

    private var ledBy: some View {
        Group {
            #if os(macOS)
            Text("Goal · \(goal.isOpen ? "" : "done · ")led by \(title(goal.lead)) · started \(started)")
            #else
            Text("Goal · \(goal.isOpen ? "" : "done · ")led by \(title(goal.lead))")
            #endif
        }
        .font(.canvas(13, .footnote, weight: .semibold))
        .foregroundStyle(accent)
    }

    /// On iOS the lead line and the ring sit beside the back button, as on the canvas.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            #if os(macOS)
            ledBy
            #endif
            Text(goal.title)
                .font(.pageTitle)
                #if os(macOS)
                .tracking(-0.7)
                #endif
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
        }
    }

    private var leadState: AgentState {
        agents.first { $0.name == goal.lead }?.state ?? .idle
    }

    @ViewBuilder private var nextFromYou: some View {
        if !goal.nextFromYou.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Next from you").font(.sectionTitle)
                ForEach(Array(goal.nextFromYou.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.canvas(14, .subheadline))
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.needsYouSoft, in: .rect(cornerRadius: 20))
        }
    }

    private var plan: some View {
        card {
            HStack(alignment: .firstTextBaseline) {
                Text("Plan").font(.sectionTitle)
                Spacer(minLength: 8)
                if !goal.steps.isEmpty {
                    Text("\(goal.progressWords) · kept up to date by \(title(goal.lead))")
                        .font(.canvas(13, .footnote))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            .padding(.bottom, 4)
            if goal.steps.isEmpty {
                Text("\(title(goal.lead)) hasn't written a plan yet.")
                    .font(.canvas(14, .subheadline))
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 9)
            }
            ForEach(Array(goal.steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: 12) {
                    StepMark(state: step.state, color: looks[goal.lead].color)
                    Text(step.text)
                        .font(.canvas(14, .subheadline))
                        .foregroundStyle(step.state == .done ? AnyShapeStyle(Theme.muted) : AnyShapeStyle(Theme.ink))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    owner(step.owner)
                }
                .padding(.vertical, 9)
                .overlay(alignment: .top) { Rectangle().fill(Theme.ink.opacity(0.05)).frame(height: 1) }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(step.state.presentation.word): \(step.text), \(title(step.owner))")
            }
        }
    }

    /// A step's owner as a dot of its colour: a helper wears its lead's.
    private func owner(_ name: String) -> some View {
        let helping = goal.helpers.contains { $0.name == name && $0.keptAt == nil }
        return HStack(spacing: 6) {
            Circle()
                .fill(looks[helping ? goal.lead : name].color.rgb.color)
                .frame(width: 8, height: 8)
            Text(title(name))
                .font(.canvas(12, .caption))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var results: some View {
        if !goal.results.isEmpty {
            let tile = AgentPalette(BloubColorId.green, dark: scheme == .dark)
            VStack(alignment: .leading, spacing: 8) {
                Text("Results so far")
                    .font(.canvas(13, .footnote, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(Array(goal.results.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(tile.softText.color)
                                .frame(width: 40, height: 40)
                                .background(tile.soft.color, in: .rect(cornerRadius: 11))
                            Text(line)
                                .font(.canvas(14, .subheadline, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(3)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 10))
                        .background(Theme.card, in: .rect(cornerRadius: 16))
                        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline) }
                    }
                }
            }
        }
    }

    private var helpers: some View {
        card(spacing: 12) {
            Text("On it").font(.sectionTitle)
            Button { onOpenAgent(goal.lead) } label: {
                HStack(alignment: .top, spacing: 10) {
                    BloubView(state: leadState.bloub, identity: looks[goal.lead], size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(goal.lead)).font(.canvas(13, .footnote, weight: .bold))
                        Text("Leads the goal · \(leadState.presentation.word)")
                            .font(.canvas(12, .caption))
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            ForEach(goal.helpers) { helper in
                helperRow(helper)
            }
            let keepable = goal.isOpen ? goal.helpers.filter(\.canBeKept) : []
            if goal.isOpen && !goal.helpers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Helpers are removed when the goal is done, unless you keep them.")
                        .font(.canvas(12, .caption))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(keepable) { helper in
                        Button("Keep \(title(helper.name)) as an agent") { keep(helper) }
                            .buttonStyle(.plain)
                            .font(.canvas(13, .footnote, weight: .semibold))
                            .foregroundStyle(accent)
                            .disabled(working)
                        if let refused = keepTrouble[helper.name] {
                            Text(refused).font(.caption).foregroundStyle(Theme.failed)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            }
        }
    }

    private func chip(_ text: String, _ color: some ShapeStyle = Theme.secondary) -> some View {
        Text(text)
            .font(.canvas(11, .caption2, weight: .bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Theme.ink.opacity(0.06), in: .rect(cornerRadius: 9))
    }

    private func helperRow(_ helper: GoalHelper) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if helper.keptAt == nil {
                HelperBloub(state: helper.state, name: helper.name, lead: goal.lead, size: 30)
            } else {
                BloubView(state: helper.state.bloub, identity: looks[helper.name], size: 30)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title(helper.name)).font(.canvas(13, .footnote, weight: .bold))
                    Spacer(minLength: 4)
                    if agents.contains(where: { $0.name == helper.name }) {
                        Button("Open") { onOpenAgent(helper.name) }
                            .buttonStyle(.pill(.secondary))
                            .controlSize(.small)
                    }
                }
                StateLine(
                    state: helper.state,
                    identity: looks[helper.name].helping(looks[goal.lead]),
                    font: .canvas(12, .caption)
                )
                HStack(spacing: 4) {
                    chip(helper.kind.word)
                    if helper.keptAt == nil { chip("For this goal") } else { chip("Kept as agent", Theme.done) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(title(goal.lead))'s choice")
                        .font(.canvas(11, .caption2, weight: .bold))
                        .foregroundStyle(accent)
                    Text(helper.reason)
                        .font(.canvas(11, .caption2))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.ground, in: .rect(cornerRadius: 8))
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { onOpenAgent(goal.lead) } label: {
                Text("Open \(title(goal.lead))'s thread").frame(maxWidth: .infinity)
            }
            .buttonStyle(.pill(.outline(nil)))
            HStack(spacing: 8) {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Text("Delete").frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill(.secondary))
                if goal.isOpen {
                    Button { run { _ = try await $0.finishGoal(id: goal.id) } } label: {
                        Text("Finish goal").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.pill(.secondary))
                }
            }
            if let trouble {
                Text(trouble)
                    .font(.footnote)
                    .foregroundStyle(Theme.failed)
            }
        }
        .disabled(working)
    }

    private func card<Content: View>(spacing: CGFloat = 0, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
            .foregroundStyle(Theme.ink)
            #if os(macOS)
            .padding(18)
            #else
            .padding(14)
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.hairline) }
    }

    private func keep(_ helper: GoalHelper) {
        keepTrouble[helper.name] = nil
        working = true
        Task {
            do {
                _ = try await session.run { try await $0.keepHelper(goal: goal.id, name: helper.name) }
                await onChanged()
            } catch {
                if !error.isCancellation { keepTrouble[helper.name] = error.localizedDescription }
            }
            working = false
        }
    }

    private func run(_ call: @escaping (SchermesClient) async throws -> Void, then: @escaping () -> Void = {}) {
        trouble = nil
        working = true
        Task {
            do {
                try await session.run(call)
                then()
                await onChanged()
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            working = false
        }
    }
}
