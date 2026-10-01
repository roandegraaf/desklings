import SwiftUI

/// A message, a file, or a file with the message it came in, about to be passed on.
struct Forwarding: Identifiable {
    let id = UUID()
    var messageId: Int?
    var file: ForwardFile?

    func request(note: String) -> ForwardRequest {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return ForwardRequest(messageId: messageId, file: file, note: trimmed.isEmpty ? nil : trimmed)
    }

    var fileName: String? { file.map { ($0.path as NSString).lastPathComponent } }
}

/// Held once per chat, so rows and file cards deep inside them can ask for the sheet without a
/// closure that would make every row unequal on each redraw.
@Observable
final class Forwarder {
    var pending: Forwarding?
}

/// Who a thing can be passed on to: agents with a home of their own, not the one it came from.
func forwardTargets(_ agents: [Agent], excluding: String?) -> [Agent] {
    agents.filter { $0.parentId == nil && $0.name != excluding }
}

struct ForwardSheet: View {
    let session: Session
    let forwarding: Forwarding
    let excluding: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(AgentLooks.self) private var looks
    @State private var agents: [Agent]?
    @State private var picked: Agent?
    @State private var note = ""
    @State private var sending = false
    @State private var trouble: String?

    var body: some View {
        ThemedForm {
            Section {
                if let agents {
                    if agents.isEmpty {
                        Text("There is no other agent to send this to.").foregroundStyle(Theme.muted)
                    }
                    ForEach(agents) { agent in
                        row(agent)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } header: {
                Text("Send to").formHeader()
            }
            Section {
                TextField(picked.map { "Note for \($0.title)" } ?? "Note", text: $note, axis: .vertical)
                    .lineLimit(2...6)
                if let trouble {
                    Label(trouble, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.failed)
                }
            } header: {
                Text(heading).formHeader()
            } footer: {
                if forwarding.messageId != nil {
                    Text("\(picked?.title ?? "It") also gets the message, so it knows what this is.")
                }
            }
        }
        .sheetChrome(
            "Send to",
            confirm: "Send",
            confirmDisabled: picked == nil || sending,
            cancel: { dismiss() },
            onConfirm: send
        )
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.ground)
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 440, minHeight: 420)
        #endif
        .task { await load() }
    }

    private var heading: String {
        switch (picked, forwarding.fileName) {
        case let (agent?, name?): "To \(agent.title), with \(name)"
        case let (agent?, nil): "To \(agent.title)"
        case let (nil, name?): "With \(name)"
        case (nil, nil): "Note"
        }
    }

    private func row(_ agent: Agent) -> some View {
        Button { picked = agent } label: {
            HStack(spacing: 10) {
                BloubView(state: .idle, identity: looks[agent.name], size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.title)
                        .font(.body.weight(.semibold))
                        .fontDesign(.rounded)
                    if let line = agent.tagline {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if picked?.name == agent.name {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked?.name == agent.name ? .isSelected : [])
    }

    private func load() async {
        do {
            let all = try await session.run { try await $0.agents() }
            agents = forwardTargets(all, excluding: excluding)
        } catch {
            agents = []
            trouble = error.localizedDescription
        }
    }

    private func send() {
        guard let picked else { return }
        sending = true
        trouble = nil
        let request = forwarding.request(note: note)
        Task {
            do {
                _ = try await session.run { try await $0.forward(to: picked.name, request) }
                dismiss()
            } catch {
                trouble = error.localizedDescription
            }
            sending = false
        }
    }
}
