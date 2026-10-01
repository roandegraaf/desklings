import SwiftUI

struct DiffLine: Hashable {
    let added: Bool
    let text: String
}

/// What a pass changed in MEMORY.md: removed lines, then added ones, each in file order. Blank
/// lines are left out.
func memoryDiff(before: String, after: String) -> [DiffLine] {
    let lines = { (text: String) in text.components(separatedBy: "\n") }
    let changes = lines(after).difference(from: lines(before))
    func kept(_ change: CollectionDifference<String>.Change, added: Bool) -> DiffLine? {
        switch change {
        case .remove(_, let line, _), .insert(_, let line, _):
            line.trimmingCharacters(in: .whitespaces).isEmpty ? nil : DiffLine(added: added, text: line)
        }
    }
    return changes.removals.compactMap { kept($0, added: false) } + changes.insertions.compactMap { kept($0, added: true) }
}

extension IdlePass {
    /// The pass in one line, where its outputs don't speak for it.
    var summary: String? {
        switch outcome {
        case .skipped: "Had nothing new, so it didn't run, 0 tokens."
        case .due: reason.map { "Didn't run: \($0)." } ?? "Still at it."
        case .wasted: "Looked, found nothing."
        case .ran: outputs.isEmpty ? "Looked, found nothing." : nil
        case .other(let raw): raw
        }
    }
}

extension IdleOutput {
    var resolvedWord: String? {
        switch resolved {
        case nil: nil
        case "undone": "Undone"
        case "accepted": "Turned on"
        case "dismissed": "Dismissed"
        case let raw?: raw.capitalized
        }
    }
}

/// What the agents did while idle over the last day, one group per agent. Answers happen in place;
/// a cleanup is answered as its request in Needs you.
struct LastNight: View {
    let session: Session
    let agents: [Agent]
    let approvals: [Approval]
    let titles: [String: String]

    @State private var passes: [IdlePass]?
    @State private var trouble: String?

    private var groups: [(agent: String, passes: [IdlePass])] {
        let byAgent = Dictionary(grouping: passes ?? [], by: \.agent)
        return byAgent
            .map { (agent: $0.key, passes: $0.value) }
            .sorted { ($1.passes.last?.startedAt ?? 0, $0.agent) < ($0.passes.last?.startedAt ?? 0, $1.agent) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let passes, passes.isEmpty {
                Text("What your agents do while you're away will show here.")
                    .font(.canvas(13, .subheadline))
                    .foregroundStyle(Theme.muted)
            } else if passes == nil, let trouble {
                Text(trouble)
                    .font(.canvas(13, .footnote))
                    .foregroundStyle(Theme.failed)
            }
            ForEach(groups, id: \.agent) { group in
                IdleAgentGroup(
                    session: session,
                    agent: agents.first { $0.name == group.agent },
                    name: group.agent,
                    titles: titles,
                    passes: group.passes,
                    approvals: approvals
                ) { changed in
                    passes = passes?.map { pass in
                        var pass = pass
                        pass.outputs = pass.outputs.map { $0.id == changed.id ? changed : $0 }
                        return pass
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func load() async {
        let since = Int(Date().timeIntervalSince1970 * 1000) - 86_400_000
        do {
            passes = try await session.run { try await $0.idlePasses(since: since) }
            trouble = nil
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }
}

private struct IdleAgentGroup: View {
    let session: Session
    let agent: Agent?
    let name: String
    let titles: [String: String]
    let passes: [IdlePass]
    let approvals: [Approval]
    let onChange: (IdleOutput) -> Void

    @Environment(AgentLooks.self) private var looks

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                BloubView(state: agent?.state.bloub ?? .idle, identity: looks[name], size: 24)
                Text(titles[name] ?? name)
                    .font(.canvas(13, .subheadline, weight: .bold))
                    .fontDesign(.rounded)
            }
            ForEach(passes) { pass in
                if let summary = pass.summary {
                    Text(summary)
                        .font(.canvas(13, .footnote))
                        .foregroundStyle(Theme.muted)
                }
                ForEach(pass.outputs) { output in
                    IdleOutputRow(session: session, output: output, agent: name, approvals: approvals, titles: { titles[$0] ?? $0 }, onChange: onChange)
                }
            }
        }
    }
}

private struct IdleOutputRow: View {
    let session: Session
    let output: IdleOutput
    let agent: String
    let approvals: [Approval]
    let titles: (String) -> String
    let onChange: (IdleOutput) -> Void

    @State private var acting = false
    @State private var trouble: String?

    @Environment(AgentLooks.self) private var looks
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if let word = output.resolvedWord {
                    Text(word)
                        .font(.canvas(12, .caption, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                } else {
                    buttons.disabled(acting)
                }
            }
            .controlSize(.small)
            if let trouble {
                Text(trouble)
                    .font(.canvas(13, .footnote))
                    .foregroundStyle(Theme.failed)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ground, in: .rect(cornerRadius: 12))
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.canvas(13, .subheadline, weight: .bold))
    }

    @ViewBuilder private var content: some View {
        switch output.kind {
        case .memory(let before, let after):
            heading("Tidied its memory")
            let lines = memoryDiff(before: before, after: after)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.prefix(8).enumerated()), id: \.offset) { _, line in
                    Text("\(line.added ? "+" : "−") \(line.text)")
                        .foregroundStyle(line.added ? Theme.done : Theme.failed)
                        .lineLimit(2)
                }
                if lines.count > 8 {
                    Text("and \(lines.count - 8) more lines")
                        .foregroundStyle(Theme.muted)
                }
            }
            .font(.canvas(11, .caption).monospaced())
        case .routine(let cron, let prompt):
            heading("Suggests a routine")
            Text(cadence(cron) ?? cron)
                .font(.canvas(12, .caption, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            Text(prompt)
                .font(.canvas(13, .footnote))
                .foregroundStyle(Theme.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        case .note(let text):
            heading("Noticed something")
            Text(text)
                .font(.canvas(13, .footnote))
                .foregroundStyle(Theme.secondary)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
        case .cleanup(let approvalId):
            heading("Proposes a cleanup")
            Group {
                if let approval = approvals.first(where: { $0.id == approvalId }) {
                    Text("It \(approval.asks(titles)). Answer it in Needs you.")
                } else {
                    Text("Asked to delete something. Already answered.")
                }
            }
            .font(.canvas(13, .footnote))
            .foregroundStyle(Theme.secondary)
        case .other(let raw):
            heading("Left a \(raw)")
        }
    }

    @ViewBuilder private var buttons: some View {
        switch output.kind {
        case .memory:
            Button("Undo") { act(.undo) }
                .buttonStyle(.pill(.secondary))
        case .routine:
            Button("Dismiss") { act(.dismiss) }
                .buttonStyle(.pill(.secondary))
            Button("Turn on") { act(.accept) }
                .buttonStyle(.pill(.agent(looks[agent].color)))
        case .note:
            Button("Dismiss") { act(.dismiss) }
                .buttonStyle(.pill(.secondary))
        case .cleanup, .other:
            EmptyView()
        }
    }

    private func act(_ action: IdleOutputAction) {
        acting = true
        trouble = nil
        Task {
            do {
                onChange(try await session.run { try await $0.resolveIdleOutput(id: output.id, action) })
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            acting = false
        }
    }
}

/// When the agent works on its own while nobody is waiting on it. Every change is written straight
/// through; the daemon's answer is what stays on screen, and its refusal shows under the field.
struct IdleSettingsView: View {
    let session: Session
    let agent: Agent
    /// A form page, or the settings page's "When idle" card (Mac).
    var card = false

    @State private var idle: IdleSettings?
    @State private var models: [ModelEntry] = []
    @State private var budget = ""
    @State private var trouble: [Field: String] = [:]
    @FocusState private var budgetFocused: Bool

    @Environment(\.colorScheme) private var scheme
    @Environment(AgentLooks.self) private var looks

    private enum Field { case load, enabled, conditions, hours, turnCap, budget, model }

    private static let conditionWords = [
        "new_messages": "New messages since the last pass",
        "new_feedback": "You gave feedback on a reply",
        "memory_size": "MEMORY.md grew past 8 KB",
        "stale_files": "Files untouched for 30 days",
    ]

    var body: some View {
        Group {
            #if os(macOS)
            if card { cardBody } else { form }
            #else
            form
            #endif
        }
        .tint(looks[agent.name].palette(dark: scheme == .dark).accentText.color)
        .task(id: agent.name) { await load() }
        .onChange(of: budgetFocused) { _, focused in if !focused { saveBudget() } }
    }

    private var form: some View {
        ThemedForm {
            if let idle {
                if let reason = idle.pausedReason {
                    Section {
                        Text("Paused: \(reason)")
                        Button("Turn back on") { save(IdleSettingsUpdate(enabled: true), .enabled) }
                            .buttonStyle(.pill(.primary))
                    }
                }
                Section {
                    Toggle("Work while idle", isOn: enabled(idle))
                    troubleText(.enabled)
                } footer: {
                    Text("May rewrite memory, with undo, and make suggestions. Never deletes or sends while idle.")
                }

                Section {
                    ForEach(conditions(idle), id: \.self) { condition in
                        Toggle(Self.conditionWords[condition] ?? condition, isOn: wakes(idle, on: condition))
                    }
                    troubleText(.conditions)
                } header: {
                    Text("Only wakes up when").formHeader()
                } footer: {
                    Text("Checked without the model: a pass that finds none of these spends nothing.")
                }

                Section {
                    hourPicker("From", idle.startHour) { IdleSettingsUpdate(startHour: $0) }
                    hourPicker("Until", idle.endHour) { IdleSettingsUpdate(endHour: $0) }
                    troubleText(.hours)
                    #if os(macOS)
                    LabeledContent("Model calls per pass") {
                        HStack(spacing: 6) {
                            Text("\(idle.turnCap)").monospacedDigit().foregroundStyle(Theme.secondary)
                            Stepper("Model calls per pass", value: turnCap(idle), in: 1...200).labelsHidden()
                        }
                    }
                    #else
                    Stepper(value: turnCap(idle), in: 1...200) {
                        LabeledContent("Model calls per pass", value: "\(idle.turnCap)")
                    }
                    #endif
                    troubleText(.turnCap)
                    LabeledContent("Daily budget") {
                        HStack(spacing: 4) {
                            TextField("Daily budget", text: $budget, prompt: Text("200000"))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .focused($budgetFocused)
                                .onSubmit(saveBudget)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                            Text("tokens").foregroundStyle(Theme.muted)
                        }
                    }
                    troubleText(.budget)
                    ValueMenu("Model", value: modelName(idle), selection: model(idle)) {
                        modelOptions
                    }
                    troubleText(.model)
                } header: {
                    Text("Runs").formHeader()
                } footer: {
                    Text("Hours are on the daemon's clock; the same hour twice means all day.")
                }
            } else if let message = trouble[.load] {
                Text(message).font(.footnote).foregroundStyle(Theme.failed)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .refreshable { await load() }
    }

    #if os(macOS)
    /// MacSettings' "When idle": checkboxes, then each run setting as a label and a bold value.
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("When idle").font(.sectionTitle).frame(maxWidth: .infinity, alignment: .leading)
                if let idle {
                    Toggle("On", isOn: enabled(idle))
                        .toggleStyle(.checkbox)
                        .fontWeight(.semibold)
                        .accessibilityLabel("Work while idle")
                }
            }
            if let idle {
                if let reason = idle.pausedReason {
                    HStack(spacing: 8) {
                        Text("Paused: \(reason)")
                            .foregroundStyle(Theme.needsYou)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Turn back on") { save(IdleSettingsUpdate(enabled: true), .enabled) }
                            .buttonStyle(.pill(.secondary))
                            .controlSize(.small)
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                troubleText(.enabled)
                Text("Only wakes up when, checked without the model:")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                ForEach(conditions(idle), id: \.self) { condition in
                    Toggle(Self.conditionWords[condition] ?? condition, isOn: wakes(idle, on: condition))
                        .toggleStyle(.checkbox)
                }
                troubleText(.conditions)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                valueRow("Daily budget") {
                    TextField("Daily budget", text: $budget, prompt: Text("200000"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .fontWeight(.semibold)
                        .frame(width: 90)
                        .focused($budgetFocused)
                        .onSubmit(saveBudget)
                    Text("tokens").foregroundStyle(Theme.muted)
                }
                troubleText(.budget)
                valueRow("Model") {
                    ValueMenu("Model", value: modelName(idle), selection: model(idle)) {
                        modelOptions
                    }
                    .labelsHidden()
                }
                troubleText(.model)
                valueRow("Runs") {
                    ValueMenu("From", value: hourText(idle.startHour), selection: hour(idle.startHour) { IdleSettingsUpdate(startHour: $0) }) {
                        hourOptions
                    }
                    .labelsHidden()
                    Text("to").foregroundStyle(Theme.muted)
                    ValueMenu("Until", value: hourText(idle.endHour), selection: hour(idle.endHour) { IdleSettingsUpdate(endHour: $0) }) {
                        hourOptions
                    }
                    .labelsHidden()
                }
                troubleText(.hours)
                valueRow("Model calls per pass") {
                    Text("\(idle.turnCap)").fontWeight(.semibold).monospacedDigit()
                    Stepper("Model calls per pass", value: turnCap(idle), in: 1...200).labelsHidden()
                }
                troubleText(.turnCap)
                Text("May rewrite memory, with undo, and make suggestions. Never deletes or sends while idle. Hours are on the daemon's clock.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message = trouble[.load] {
                Text(message).font(.footnote).foregroundStyle(Theme.failed)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.ink)
    }

    private func valueRow(_ title: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(Theme.secondary)
            Spacer(minLength: 8)
            value()
        }
    }

    #endif

    private var hourOptions: some View {
        ForEach(0..<24, id: \.self) { Text(hourText($0)).tag($0) }
    }

    private func modelName(_ idle: IdleSettings) -> String {
        idle.modelId.flatMap { id in models.first { $0.id == id }?.name } ?? "Agent's own"
    }
    private var modelOptions: some View {
        Group {
            Text("Agent's own").tag(Int?.none)
            ForEach(models) { entry in
                Text(entry.name).tag(Optional(entry.id))
            }
        }
    }

    private func enabled(_ idle: IdleSettings) -> Binding<Bool> {
        Binding(get: { idle.enabled }, set: { save(IdleSettingsUpdate(enabled: $0), .enabled) })
    }

    private func wakes(_ idle: IdleSettings, on condition: String) -> Binding<Bool> {
        Binding(
            get: { idle.conditions.contains(condition) },
            set: { on in
                let next = conditions(idle).filter { $0 == condition ? on : idle.conditions.contains($0) }
                save(IdleSettingsUpdate(conditions: next), .conditions)
            }
        )
    }

    private func turnCap(_ idle: IdleSettings) -> Binding<Int> {
        Binding(get: { idle.turnCap }, set: { save(IdleSettingsUpdate(turnCap: $0), .turnCap) })
    }

    private func model(_ idle: IdleSettings) -> Binding<Int?> {
        Binding(get: { idle.modelId }, set: { save(IdleSettingsUpdate(modelId: .some($0)), .model) })
    }

    private func hour(_ hour: Int, _ update: @escaping (Int) -> IdleSettingsUpdate) -> Binding<Int> {
        Binding(get: { hour }, set: { save(update($0), .hours) })
    }

    private func hourText(_ hour: Int) -> String { String(format: "%02d:00", hour) }

    private func conditions(_ idle: IdleSettings) -> [String] {
        IdleSettings.allConditions + idle.conditions.filter { !IdleSettings.allConditions.contains($0) }
    }

    @ViewBuilder private func troubleText(_ field: Field) -> some View {
        if let message = trouble[field] {
            Text(message).font(.footnote).foregroundStyle(Theme.failed)
        }
    }

    private func hourPicker(_ label: String, _ hour: Int, _ update: @escaping (Int) -> IdleSettingsUpdate) -> some View {
        ValueMenu(label, value: hourText(hour), selection: self.hour(hour, update)) { hourOptions }
    }

    private func saveBudget() {
        guard let idle, String(idle.dailyTokens) != budget else { return }
        guard let tokens = Int(budget.filter { !$0.isWhitespace }) else {
            trouble[.budget] = "Enter a whole number of tokens."
            return
        }
        save(IdleSettingsUpdate(dailyTokens: tokens), .budget)
    }

    private func load() async {
        do {
            let loaded = try await session.run { try await $0.idle(agent: agent.name) }
            idle = loaded
            budget = String(loaded.dailyTokens)
            trouble[.load] = nil
        } catch {
            if !error.isCancellation { trouble[.load] = error.localizedDescription }
        }
        models = (try? await session.run { try await $0.models() }) ?? models
    }

    private func save(_ update: IdleSettingsUpdate, _ field: Field) {
        trouble[field] = nil
        Task {
            do {
                let saved = try await session.run { try await $0.setIdle(agent: agent.name, update) }
                idle = saved
                if field == .budget || !budgetFocused { budget = String(saved.dailyTokens) }
            } catch {
                if !error.isCancellation { trouble[field] = error.localizedDescription }
            }
        }
    }
}
