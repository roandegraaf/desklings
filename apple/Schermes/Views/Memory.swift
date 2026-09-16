import SwiftUI

/// What the agent carries between conversations, read from its home. `MEMORY.md` is the owner's
/// to correct, because a wrong fact there is repeated every turn; today's note is the agent's
/// own log and is shown as it is.
struct MemoryView: View {
    let session: Session
    let agent: Agent

    @State private var stored: MemoryFiles?
    @State private var lasting = ""
    @State private var trouble: String?
    @State private var saving = false

    private var changed: Bool { stored.map { $0.lasting != lasting } ?? false }

    var body: some View {
        Form {
            Section {
                if stored != nil {
                    TextEditor(text: $lasting)
                        .font(.callout.monospaced())
                        .frame(minHeight: 160)
                    // Borderless, or a Form row with two buttons fires both on one tap.
                    HStack(spacing: 16) {
                        Button(saving ? "Saving…" : "Save", action: save)
                            .disabled(saving || !changed)
                        if changed {
                            Button("Revert") { lasting = stored?.lasting ?? "" }
                        }
                    }
                    .buttonStyle(.borderless)
                    if let trouble {
                        Text(trouble)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } else if let trouble {
                    Text(trouble).foregroundStyle(.red)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } header: {
                Text("Lasting memory")
            } footer: {
                Text("~/memory/MEMORY.md, shown to \(agent.title) at the start of every turn. One fact per line. The agent adds to it with `remember`; you can correct it here.")
            }

            Section {
                if let stored {
                    if stored.today.isEmpty {
                        Text("Nothing noted today.").foregroundStyle(.secondary)
                    } else {
                        Text(stored.today)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Today's note")
            } footer: {
                Text("What it jotted down today. Not loaded into its prompt, but on disk for it to search.")
            }
        }
        .formStyle(.grouped)
        .autocorrectionDisabled()
        .task(id: agent.name) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let files = try await session.run { try await $0.memory(agent: agent.name) }
            // A reload under an edit keeps the edit: the file changing under the owner is the
            // agent remembering something, which the next save would otherwise erase.
            if !changed { lasting = files.lasting }
            stored = files
            trouble = nil
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        trouble = nil
        let text = lasting
        Task {
            do {
                let files = try await session.run { try await $0.saveMemory(agent: agent.name, lasting: text) }
                stored = files
                lasting = files.lasting
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            saving = false
        }
    }
}
