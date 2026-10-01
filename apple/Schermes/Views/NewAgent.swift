import SwiftUI

/// What the sheet holds between Suggest and Create, all of it editable.
struct NewAgentPlan: Equatable {
    var description = ""
    var label = ""
    var tagline = ""
    var levels: [String: RuleLevel] = [:]
    var routine: Routine?

    var described: Bool { !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    mutating func adopt(_ suggestion: AgentSuggestion) {
        label = suggestion.label
        tagline = suggestion.tagline
        levels = suggestion.levels
        routine = suggestion.routine
    }

    /// Without a description it is the plain create it always was; the rest only travels with one.
    func request(name: String, look: String) -> AgentCreate {
        let label = label.trimmingCharacters(in: .whitespaces)
        guard described else { return AgentCreate(name: name, label: label, look: look) }
        let tagline = tagline.trimmingCharacters(in: .whitespaces)
        let routine = routine.map {
            Routine(cron: $0.cron.trimmingCharacters(in: .whitespaces), prompt: $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return AgentCreate(
            name: name,
            label: label,
            look: look,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            tagline: tagline.isEmpty ? nil : tagline,
            levels: levels.isEmpty ? nil : levels.filter { $0.key != RuleRow.locked.category },
            routine: routine.flatMap { $0.cron.isEmpty || $0.prompt.isEmpty ? nil : $0 }
        )
    }
}

struct NewAgentSheet: View {
    let session: Session
    /// The names already in use, so the slug this sheet derives is one the daemon will accept.
    let taken: Set<String>
    let onCreated: (Agent) -> Void

    @Environment(AgentLooks.self) private var looks
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var plan = NewAgentPlan()
    @State private var suggested = false
    @State private var trouble: String?
    @State private var working = false
    @State private var suggesting = false
    /// nil means the look still follows the name, so typing one shows what it would look like.
    @State private var chosen: BloubIdentity?

    private var identity: BloubIdentity {
        chosen ?? .standard(for: slug)
    }

    private var wanted: String { plan.label.trimmingCharacters(in: .whitespaces) }

    /// What the agent runs as, derived from what the owner typed and shown before they commit to
    /// it: it is the Linux user, the other agents' address for it, and it never changes after.
    private var slug: String { agentName(for: wanted, taken: taken) }

    /// The daemon's own rule, checked here so an empty or overlong name is answered as it is
    /// typed rather than by a round trip. The daemon checks it again; this is the keyboard's half.
    private var nameIsFine: Bool { isAgentLabel(wanted) }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            SheetHeader("New agent") {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.pill(.secondary))
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            content
        }
        .background(tint)
        .presentationBackground(tint)
        // Wide enough for all twelve colours: a Mac sheet sizes to its content and a half-drawn
        // swatch at the edge reads as a bug.
        .frame(minWidth: 500, minHeight: 560)
        #else
        content
            .background(tint)
            .presentationBackground(tint)
            .frame(minWidth: 320)
        #endif
    }

    private var tint: Color { identity.palette(dark: scheme == .dark).tint.color }

    private var content: some View {
        ScrollView {
            VStack(spacing: 18) {
                #if os(iOS)
                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.plain)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                }
                .overlay { Text("New agent").font(.headline).foregroundStyle(Theme.ink) }
                #endif

                BloubView(state: .idle, identity: identity, size: 96)
                    .padding(.top, 8)

                describe

                TextField("name", text: $plan.label)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Theme.card, in: .capsule)
                    .onSubmit(create)

                if plan.described {
                    TextField("What it's for, in a few words", text: $plan.tagline)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Theme.card, in: .capsule)
                }

                BloubPicker(identity: Binding(get: { identity }, set: { chosen = $0 }))

                if suggested && plan.described {
                    VStack(alignment: .leading, spacing: 14) {
                        startingRules
                        routine
                    }
                    .padding(16)
                    .background(Theme.card, in: .rect(cornerRadius: 20))
                    .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.hairline) }
                }

                status

                Text(plan.described
                    ? "Its desktop starts in the background while \(wanted.isEmpty ? "it" : wanted) asks you a few questions."
                    : "Call it whatever you like. Creating one makes a Linux user and starts a desktop, so it is slow on purpose.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)

                createButton
            }
            .padding(.horizontal, 20)
            #if os(macOS)
            .padding(.top, 6)
            .padding(.bottom, 18)
            #else
            .padding(.vertical, 18)
            #endif
        }
    }

    /// A trailing pill on the Mac, so disabled it reads as a faded pill rather than a grey slab.
    private var createButton: some View {
        Button(action: create) {
            Text(working ? "Creating…" : nameIsFine ? "Create \(wanted)" : "Create")
                #if os(iOS)
                .frame(maxWidth: .infinity)
                #endif
        }
        .buttonStyle(.pill(.primary))
        #if os(macOS)
        .frame(maxWidth: .infinity, alignment: .trailing)
        #else
        .controlSize(.large)
        #endif
        .disabled(working || suggesting || !nameIsFine)
    }

    private var describe: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What should it help you with?")
                .font(.system(.title2, design: .rounded, weight: .bold))
            TextField("Keep an eye on the support inbox and draft replies in my tone.", text: $plan.description, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...6)
                .padding(14)
                .background(Theme.card, in: .rect(cornerRadius: 18))
            HStack {
                Spacer()
                Button(suggesting ? "Suggesting…" : suggested ? "Suggest again" : "Suggest", action: suggest)
                    .buttonStyle(.pill(.secondary))
                    .disabled(suggesting || working || !plan.described)
            }
        }
    }

    private var startingRules: some View {
        DisclosureGroup {
            ForEach(RuleRow.editable(runsAs: "agent-\(slug)")) { row in
                HStack {
                    Text(row.name).font(.subheadline)
                    Spacer(minLength: 8)
                    let level = plan.levels[row.category] ?? .other("unset")
                    ValueMenu(row.name, value: level.word, selection: Binding(
                        get: { level },
                        set: { plan.levels[row.category] = $0 }
                    )) {
                        ForEach(RuleLevel.ladder, id: \.self) { Text($0.word).tag($0) }
                    }
                    .labelsHidden()
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rules").font(.subheadline.weight(.semibold))
                Text(rulesSummary(plan.levels)).font(.footnote).foregroundStyle(Theme.muted)
            }
        }
    }

    @ViewBuilder
    private var routine: some View {
        if let current = plan.routine {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("First routine").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Leave out", role: .destructive) { plan.routine = nil }
                        .buttonStyle(.borderless)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.failed)
                }
                if let words = cadence(current.cron) {
                    Text(words).font(.footnote).foregroundStyle(Theme.muted)
                }
                TextField("Cron", text: Binding(
                    get: { plan.routine?.cron ?? "" },
                    set: { plan.routine?.cron = $0 }
                ))
                .font(.body.monospaced())
                .autocorrectionDisabled()
                TextField("What it does then", text: Binding(
                    get: { plan.routine?.prompt ?? "" },
                    set: { plan.routine?.prompt = $0 }
                ), axis: .vertical)
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var status: some View {
        if let trouble {
            Text(trouble)
                .font(.footnote)
                .foregroundStyle(Theme.failed)
                .multilineTextAlignment(.center)
        } else if !wanted.isEmpty && !nameIsFine {
            Text("One line, up to \(MAX_AGENT_LABEL) characters.")
                .font(.footnote)
                .foregroundStyle(Theme.failed)
                .multilineTextAlignment(.center)
        } else if nameIsFine {
            Text("Runs as agent-\(slug)")
                .font(.footnote.monospaced())
                .foregroundStyle(Theme.muted)
        }
    }

    private func suggest() {
        guard !suggesting, plan.described else { return }
        suggesting = true
        trouble = nil
        let description = plan.description.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let suggestion = try await session.run { try await $0.suggestAgent(description: description) }
                plan.adopt(suggestion)
                chosen = suggestion.look.flatMap(BloubIdentity.init(token:))
                suggested = true
            } catch {
                trouble = error.localizedDescription
            }
            suggesting = false
        }
    }

    private func create() {
        guard !working, nameIsFine else { return }
        working = true
        trouble = nil
        let request = plan.request(name: slug, look: identity.token)
        Task {
            do {
                let agent = try await session.run { try await $0.createAgent(request) }
                looks[agent.name] = identity
                onCreated(agent)
                dismiss()
            } catch {
                trouble = error.localizedDescription
            }
            working = false
        }
    }
}
