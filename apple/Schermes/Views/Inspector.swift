import SwiftUI

/// The third column on macOS and regular width: the agent's screen, small and live, above its
/// routines and activity. The thumbnail opens the full desktop over the same connection: in a
/// window of its own on a Mac, so it can be resized, taken full screen or watched beside the chat.
struct AgentInspector: View {
    let session: Session
    let agent: Agent

    @Environment(Desktops.self) private var desktops
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #else
    @State private var expanded = false
    #endif

    private var link: DesktopLink { desktops.link(agent.name) }

    var body: some View {
        VStack(spacing: 0) {
            thumbnail
                .padding(12)
            AgentPages(session: session, agent: agent)
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
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(12)
                } else {
                    ProgressView()
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.semibold))
                    .padding(7)
                    .glassEffect(.regular, in: .circle)
                    .padding(8)
            }
            .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(agent.title)'s screen")
        .accessibilityHint("Opens the desktop")
    }

    private var aspect: CGFloat {
        link.screen.map { CGFloat($0.width) / CGFloat($0.height) } ?? 16 / 10
    }
}
