#if os(macOS)
import SwiftUI

/// MacSettings: the agent's rules, routines and idle work in the chat's place, with name and
/// appearance (which holds the profile), memory and activity one sheet away.
struct AgentSettingsPage: View {
    let session: Session
    let agent: Agent
    let onBack: () -> Void

    @State private var dressing = false
    @State private var page: AgentPages.Page?
    @State private var width: CGFloat = 0

    @Environment(AgentLooks.self) private var looks

    /// Rules' label, its 400pt track and the 380pt column side by side; narrower stacks them.
    private var sideBySide: Bool { width >= 1000 }

    var body: some View {
        let columns = sideBySide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 22))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 22))
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                columns {
                    RulesView(session: session, agent: agent, board: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 14) {
                        RoutinesSummary(session: session, agent: agent, cardFill: Theme.ground)
                            .settingsCard()
                        IdleSettingsView(session: session, agent: agent, card: true)
                            .settingsCard()
                    }
                    .frame(width: sideBySide ? 380 : nil)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - 64 } action: { width = $0 }
        }
        .foregroundStyle(Theme.ink)
        .sheet(isPresented: $dressing) {
            AgentLookSheet(session: session, agent: agent, identity: looks[agent.name])
        }
        .sheet(item: $page) { page in
            RoutinesAndActivity(session: session, agent: agent, page: page)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                title
                Spacer(minLength: 0)
                pills
            }
            VStack(alignment: .leading, spacing: 12) {
                title
                pills
            }
        }
    }

    private var title: some View {
        HStack(spacing: 14) {
            Button("Back to the chat", systemImage: "chevron.left", action: onBack)
                .labelStyle(.iconOnly)
                .buttonStyle(.pill(.secondary, round: true))
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to the chat")
            BloubView(state: agent.state.bloub, identity: looks[agent.name], size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(agent.title)'s settings")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                HStack(spacing: 5) {
                    Text([agent.tagline, "runs as agent-\(agent.name)"].compactMap(\.self).joined(separator: " · "))
                        .foregroundStyle(Theme.muted)
                    Text("·").foregroundStyle(Theme.muted)
                    AgentModelRow(session: session, agent: agent, bare: true)
                }
                .font(.system(size: 13))
            }
            .lineLimit(1)
        }
    }

    private var pills: some View {
        HStack(spacing: 8) {
            Button("Name and appearance") { dressing = true }
            Button("Memory", systemImage: AgentPages.Page.memory.symbol) { page = .memory }
            Button("Activity", systemImage: AgentPages.Page.activity.symbol) { page = .activity }
        }
        .buttonStyle(.pill(.secondary))
        .fixedSize()
    }
}

private extension View {
    func settingsCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.hairline, lineWidth: 1) }
    }
}
#endif
