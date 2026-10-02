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
    @State private var expanded = false

    @Environment(AgentLooks.self) private var looks
    @Environment(\.colorScheme) private var scheme

    private var palette: AgentPalette { looks[agent].palette(dark: scheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
                .opacity(output.resolved == nil ? 1 : 0.6)
            if output.resolved == nil, hasButtons {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    buttons.disabled(acting)
                }
                .controlSize(.small)
            }
            if let trouble {
                Text(trouble)
                    .font(.canvas(13, .footnote))
                    .foregroundStyle(Theme.failed)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ground, in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline) }
        .animation(.snappy(duration: 0.25), value: expanded)
        .animation(.snappy(duration: 0.25), value: output.resolved)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(palette.softText.color)
                .frame(width: 24, height: 24)
                .background(palette.soft.color, in: .circle)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    titleText
                    Text(Date(timeIntervalSince1970: Double(output.createdAt) / 1000), format: .dateTime.hour().minute())
                        .font(.canvas(12, .caption))
                        .foregroundStyle(Theme.muted)
                        .monospacedDigit()
                        .fixedSize()
                }
                titleText
            }
            Spacer(minLength: 8)
            if let word = output.resolvedWord {
                Label(word, systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .font(.canvas(11, .caption2, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.ink.opacity(0.06), in: .capsule)
                    .fixedSize()
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.canvas(13, .subheadline, weight: .bold))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
    }

    private var symbol: String {
        switch output.kind {
        case .memory: "brain"
        case .routine: "clock.arrow.circlepath"
        case .note: "lightbulb"
        case .cleanup: "trash"
        case .other: "sparkles"
        }
    }

    private var title: String {
        switch output.kind {
        case .memory: "Tidied its memory"
        case .routine: "Suggests a routine"
        case .note: "Noticed something"
        case .cleanup: "Proposes a cleanup"
        case .other(let raw): "Left a \(raw)"
        }
    }

    private var hasButtons: Bool {
        switch output.kind {
        case .memory, .routine, .note: true
        case .cleanup, .other: false
        }
    }

    @ViewBuilder private var content: some View {
        switch output.kind {
        case .memory(let before, let after):
            MemoryChanges(lines: memoryDiff(before: before, after: after), expanded: $expanded)
        case .routine(let cron, let prompt):
            VStack(alignment: .leading, spacing: 6) {
                Label(cadence(cron) ?? cron, systemImage: "calendar")
                    .font(.canvas(12, .caption, weight: .semibold))
                    .foregroundStyle(palette.accentText.color)
                Folded(expanded: $expanded, long: prompt.count > 220) {
                    MarkdownText(content: prompt)
                }
            }
        case .note(let text):
            Folded(expanded: $expanded, long: text.count > 220 || text.split(separator: "\n").count > 4) {
                MarkdownText(content: text)
            }
        case .cleanup(let approvalId):
            Group {
                if let approval = approvals.first(where: { $0.id == approvalId }) {
                    Text("It \(approval.asks(titles)). Answer it in Needs you.")
                } else {
                    Text("Asked to delete something. Already answered.")
                }
            }
            .font(.canvas(13, .footnote))
            .foregroundStyle(Theme.secondary)
        case .other:
            EmptyView()
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

/// Long prose cut to a few lines that fade out, with a toggle to read the rest.
private struct Folded<Content: View>: View {
    @Binding var expanded: Bool
    let long: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
                .font(.canvas(13, .footnote))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: long && !expanded ? 88 : nil, alignment: .top)
                .clipped()
                .mask {
                    LinearGradient(
                        stops: [.init(color: .black, location: 0.6), .init(color: .black.opacity(long && !expanded ? 0 : 1), location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            if long {
                FoldToggle(expanded: $expanded, more: "Show more", less: "Show less")
            }
        }
    }
}

private struct FoldToggle: View {
    @Binding var expanded: Bool
    let more: String
    let less: String

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(expanded ? less : more)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .font(.canvas(12, .caption, weight: .semibold))
            .foregroundStyle(Theme.muted)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A memory rewrite as readable change rows: the list marker the diff would double up is dropped
/// and the line is rendered as inline markdown.
private struct MemoryChanges: View {
    let lines: [DiffLine]
    @Binding var expanded: Bool

    private static let collapsedCount = 3

    private var shown: [DiffLine] { expanded ? lines : Array(lines.prefix(Self.collapsedCount)) }

    private var tally: String {
        let added = lines.filter(\.added).count
        let removed = lines.count - added
        return [
            removed > 0 ? "\(removed) removed" : nil,
            added > 0 ? "\(added) added" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if lines.isEmpty {
                Text("No visible changes.")
                    .font(.canvas(13, .footnote))
                    .foregroundStyle(Theme.muted)
            } else {
                Text(tally)
                    .font(.canvas(12, .caption, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                        MemoryChangeRow(line: line, expanded: expanded)
                    }
                }
                if lines.count > Self.collapsedCount {
                    FoldToggle(
                        expanded: $expanded,
                        more: "Show all \(lines.count) changes",
                        less: "Show fewer"
                    )
                }
            }
        }
    }
}

private struct MemoryChangeRow: View {
    let line: DiffLine
    let expanded: Bool

    private var tint: Token { line.added ? Theme.done : Theme.failed }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: line.added ? "plus" : "minus")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .background(tint.opacity(0.14), in: .circle)
                .padding(.top, 1)
            Text(memoryLineText(line.text))
                .font(.canvas(13, .footnote))
                .foregroundStyle(line.added ? Theme.ink : Theme.muted)
                .strikethrough(!line.added, color: .secondary.opacity(0.4))
                .lineLimit(expanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(line.added ? "Added" : "Removed"): \(line.text)")
    }
}

func memoryLineText(_ raw: String) -> AttributedString {
    var text = raw.trimmingCharacters(in: .whitespaces)
    for marker in ["- ", "* ", "+ "] where text.hasPrefix(marker) {
        text = String(text.dropFirst(marker.count))
        break
    }
    while text.hasPrefix("#") { text.removeFirst() }
    text = text.trimmingCharacters(in: .whitespaces)
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
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
