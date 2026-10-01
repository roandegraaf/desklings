import SwiftUI

/// What the owner sends to have the agent interview them: the empty thread and the Profile
/// page both offer it, so the words live in one place.
func interviewRequest(hasProfile: Bool) -> String {
    hasProfile
        ? "Interview me again about what you should be and do: first ask me with ask_owner to describe it in a few sentences, then ask focused follow-ups, and rewrite your profile with set_profile."
        : "Find out from me what you should be and do: first ask me with ask_owner to describe it in a few sentences, then ask focused follow-ups, then write your profile with set_profile."
}

/// Who the agent is: the Markdown it wrote after interviewing the owner, in its system prompt
/// every turn. The owner rewrites it here, or sends it back to ask again.
struct ProfileView: View {
    let session: Session
    let agent: Agent
    /// No form: a section inside the name and appearance sheet.
    var bare = false
    /// Told when an edit starts or ends, so a sheet around it can hold its Done.
    var editingChanged: (Bool) -> Void = { _ in }

    /// The row the last save answered with, shown until the next list poll catches up.
    @State private var saved: Agent?
    @State private var editing = false
    @State private var draft = ""
    @State private var saving = false
    @State private var asking = false
    @State private var trouble: String?

    private var shown: Agent { saved ?? agent }

    var body: some View {
        Group {
            if bare { bareBody } else { form }
        }
        .task(id: agent.profile) { saved = nil }
        .onChange(of: editing) { _, now in editingChanged(now) }
    }

    private var form: some View {
        ThemedForm {
            Section {
                if editing {
                    editor
                    // A style of their own, or a Form row with two buttons fires both on one tap.
                    saveButtons
                } else if let profile = shown.profile {
                    MarkdownText(content: profile)
                        .textSelection(.enabled)
                    editButton(profile)
                } else {
                    emptyNote
                }
                troubleText
            } footer: {
                Text("What \(agent.title) is for, how it works and what it stays out of, in its system prompt at the start of every turn. It wrote this itself after interviewing you; correct it here when it drifts.")
            }

            Section {
                askButton
            } footer: {
                Text("Sends a message in its thread asking it to interview you and rewrite its profile from what you say.")
            }
        }
    }

    private var bareBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profile").font(.sectionTitle)
            if editing {
                editor
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Theme.ground, in: .rect(cornerRadius: 10))
                saveButtons
            } else {
                if let profile = shown.profile {
                    ScrollView {
                        MarkdownText(content: profile)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    emptyNote
                }
                HStack(spacing: 8) {
                    if let profile = shown.profile { editButton(profile) }
                    askButton
                }
            }
            troubleText
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editor: some View {
        TextEditor(text: $draft)
            .font(.callout)
            .frame(minHeight: 200)
    }

    private var saveButtons: some View {
        HStack(spacing: 8) {
            Button(saving ? "Saving…" : "Save", action: save)
                .buttonStyle(.pill(.primary))
                .disabled(saving)
            Button("Cancel") { editing = false }
                .buttonStyle(.pill(.secondary))
        }
    }

    private func editButton(_ profile: String) -> some View {
        Button("Edit") {
            draft = profile
            editing = true
        }
        .buttonStyle(.pill(.secondary))
    }

    @ViewBuilder private var emptyNote: some View {
        Text("No profile yet.").foregroundStyle(Theme.muted)
        Text("\(agent.title) asks what it is for the first time you talk, and writes the answer here.")
            .font(.footnote)
            .foregroundStyle(Theme.muted)
    }

    @ViewBuilder private var troubleText: some View {
        if let trouble {
            Text(trouble)
                .font(.footnote)
                .foregroundStyle(Theme.failed)
        }
    }

    private var askButton: some View {
        Button(asking ? "Asking…" : shown.profile == nil ? "Start the interview" : "Interview me again", action: ask)
            .buttonStyle(.pill(bare ? .secondary : .primary))
            .disabled(asking || editing)
    }

    private func save() {
        guard !saving else { return }
        saving = true
        trouble = nil
        let profile = draft
        Task {
            do {
                saved = try await session.run { try await $0.updateAgent(name: agent.name, profile: profile) }
                editing = false
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            saving = false
        }
    }

    private func ask() {
        guard !asking else { return }
        asking = true
        trouble = nil
        let text = interviewRequest(hasProfile: shown.profile != nil)
        Task {
            do {
                _ = try await session.run { try await $0.send(.agent(agent.name), text: text) }
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            asking = false
        }
    }
}
