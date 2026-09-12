import SwiftUI

/// The third column on macOS and regular width: the agent's screen, small and live, above its
/// routines and activity. The thumbnail opens the full desktop over the same connection.
struct AgentInspector: View {
    let session: Session
    let agent: Agent

    @State private var link = DesktopLink()
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            thumbnail
                .padding(12)
            AgentPages(session: session, agent: agent.name)
        }
        // Retried, unlike a desktop opened by hand: this stays up for as long as the agent is
        // picked, which is long enough to outlive a daemon restart or a Mac put to sleep.
        .task {
            while !Task.isCancelled {
                await link.run(session: session, agent: agent.name)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $expanded) { desktop }
        #else
        .sheet(isPresented: $expanded) { desktop }
        #endif
    }

    private var desktop: some View {
        NavigationStack {
            DesktopView(session: session, agent: agent, shared: link)
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 480)
        #endif
    }

    private var thumbnail: some View {
        Button { expanded = true } label: {
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
        .accessibilityLabel("\(agent.name)'s screen")
        .accessibilityHint("Opens the desktop")
    }

    private var aspect: CGFloat {
        link.screen.map { CGFloat($0.width) / CGFloat($0.height) } ?? 16 / 10
    }
}
