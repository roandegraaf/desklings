import SwiftUI

/// The third column on macOS and regular width, after Main's aside: the agent's screen, small and
/// live, its open goal and its routines and triggers. The thumbnail opens the full desktop over the
/// same connection: in a window of its own on a Mac, so it can be resized, taken full screen or
/// watched beside the chat. Its pages are reached from the chat header.
struct AgentInspector: View {
    let session: Session
    let agent: Agent
    /// The open goal it leads or helps with, shown under the screen.
    var goal: Goal? = nil
    var titles: [String: String] = [:]
    var waiting = false
    var onOpenGoal: (Int) -> Void = { _ in }

    @Environment(Desktops.self) private var desktops
    @Environment(AgentLooks.self) private var looks
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #else
    @State private var expanded = false
    #endif

    private var link: DesktopLink { desktops.link(agent.name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                screen
                if let goal {
                    GoalSummary(goal: goal, agent: agent.name, titles: titles) { onOpenGoal(goal.id) }
                }
                RoutinesSummary(session: session, agent: agent)
            }
            .foregroundStyle(Theme.ink)
            .padding(16)
        }
        .task(id: scenePhase == .background) {
            guard scenePhase != .background else { return }
            await desktops.watch(agent.name, session: session)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $expanded) {
            NavigationStack {
                DesktopView(session: session, agent: agent)
            }
        }
        #endif
    }

    private func expand() {
        #if os(macOS)
        openWindow(id: desktopWindowID, value: agent.name)
        #else
        expanded = true
        #endif
    }

    private var screen: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Screen").font(.sectionTitle)
                Spacer(minLength: 0)
                if waiting {
                    Text("PAUSED")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.needsYou)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Theme.needsYouSoft, in: .rect(cornerRadius: 9))
                }
            }
            thumbnail
            HStack(spacing: 8) {
                Button(action: takeControl) {
                    Label("Take control", systemImage: "hand.raised").frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill(.agent(looks[agent.name].color)))
                Button("Open the screen", systemImage: "arrow.up.left.and.arrow.down.right", action: expand)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.pill(.secondary, round: true))
                    .help("Open the screen")
            }
        }
    }

    private var thumbnail: some View {
        Button(action: expand) {
            ZStack {
                Color.black
                if let screen = link.screen {
                    Image(decorative: screen, scale: 1, orientation: .up)
                        .interpolation(.medium)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if let failure = link.failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                        .padding(12)
                } else {
                    ProgressView()
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 8))
            .padding(8)
            .background(Theme.screenFrame, in: .rect(cornerRadius: 14))
            .overlay {
                if waiting {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.needsYouTile, lineWidth: 2).padding(-2)
                }
            }
            .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(agent.title)'s screen")
        .accessibilityHint("Opens the desktop")
    }

    private func takeControl() {
        Task {
            _ = try? await session.run { try await $0.setControl(agent: agent.name, held: true) }
            expand()
        }
    }

    private var aspect: CGFloat {
        link.screen.map { CGFloat($0.width) / CGFloat($0.height) } ?? 16 / 10
    }
}
