import SwiftUI

/// One line of the rules: a daemon approval category in the owner's words.
struct RuleRow: Equatable, Identifiable {
    let category: String
    let name: String
    let hint: String

    var id: String { category }

    /// The canvas's order and words. Browse and run commands stay two rows, as on the Mac canvas,
    /// so a split level between them is never hidden behind one word.
    static func editable(runsAs: String) -> [RuleRow] {
        [
            RuleRow(category: "browse", name: "Browse and read", hint: "Websites, its own files, read-only apps"),
            RuleRow(category: "run_commands", name: "Run commands", hint: "As \(runsAs), in its own home"),
            RuleRow(category: "write_files", name: "Write and edit files", hint: "Its own files, mostly in ~/workspace"),
            RuleRow(category: "delete_files", name: "Delete files", hint: "Goes through Keep them or Delete"),
            RuleRow(category: "send_messages", name: "Send email and messages", hint: "To anyone who is not you"),
            RuleRow(category: "spend_money", name: "Spend money", hint: "Checkouts, subscriptions, top-ups"),
            RuleRow(category: "install_software", name: "Install software", hint: "apt, pip, npm, browser extensions"),
            RuleRow(category: "share_outside", name: "Share files outside", hint: "Links, uploads, attachments"),
        ]
    }

    /// Never delegated: the daemon refuses any other level for it.
    static let locked = RuleRow(
        category: "passwords_security",
        name: "Change passwords and security settings",
        hint: "Never delegated"
    )
}

extension RuleLevel {
    var word: String {
        switch self {
        case .onItsOwn: "On its own"
        case .ifPreApproved: "If pre-approved"
        case .askFirst: "Ask first"
        case .handToYou: "Hand to you"
        case .other(let raw): raw
        }
    }

    /// The segmented control's words, where four full phrases don't fit.
    var short: String {
        switch self {
        case .onItsOwn: "Own"
        case .ifPreApproved: "Pre-approved"
        case .askFirst: "Ask"
        case .handToYou: "Hand over"
        case .other(let raw): raw
        }
    }
}

/// What an agent may do on its own, per category, and what it may act on without asking.
/// Every change is written straight through; the daemon's answer is what stays on screen.
struct RulesView: View {
    let session: Session
    let agent: Agent
    /// A form page, or the settings page's matrix of white rows on the ground (Mac).
    var board = false

    @State private var rules: AgentRules?
    @State private var entries: [String: String] = [:]
    @State private var trouble: String?
    @State private var editingList: String?

    @Environment(\.colorScheme) private var scheme
    @Environment(AgentLooks.self) private var looks

    private var accent: Color { looks[agent.name].palette(dark: scheme == .dark).accentText.color }

    var body: some View {
        Group {
            #if os(macOS)
            if board { boardBody } else { form }
            #else
            form
            #endif
        }
        .tint(accent)
        .task(id: agent.name) { await load() }
    }

    private var form: some View {
        ThemedForm {
            Section {
                if let rules {
                    ForEach(RuleRow.editable(runsAs: agent.name)) { row in
                        levelRow(row, rules: rules)
                    }
                    lockedRow
                } else if let trouble {
                    troubleText(trouble)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } footer: {
                Text("What \(agent.title) may do on its own. If pre-approved goes ahead for what is on its list below and asks for the rest. Ask first lands in Needs you. Hand to you leaves it to you.")
            }

            if let rules {
                let lists = listed(rules)
                ForEach(lists) { row in
                    Section {
                        preApprovedRows(rules, row.category, showingTrouble: row == lists.last)
                    } header: {
                        Text("Pre-approved: \(row.name)").formHeader()
                    } footer: {
                        if row == lists.last { preApprovedFooter }
                    }
                }
                if lists.isEmpty, let trouble { Section { troubleText(trouble) } }
            }
        }
        .refreshable { await load() }
    }

    private func listed(_ rules: AgentRules) -> [RuleRow] {
        RuleRow.editable(runsAs: agent.name).filter { rules.levels[$0.category] == .ifPreApproved }
    }

    private var preApprovedFooter: Text {
        Text("What \(agent.title) may act on without asking, one list per rule set to If pre-approved. Always allow on a request adds to that rule's list.")
    }

    private func entry(_ category: String) -> Binding<String> {
        Binding(get: { entries[category, default: ""] }, set: { entries[category] = $0 })
    }

    @ViewBuilder private func preApprovedRows(_ rules: AgentRules, _ category: String, showingTrouble: Bool = true) -> some View {
        let list = rules.preApproved[category] ?? []
        ForEach(list, id: \.self) { item in
            HStack {
                Text(item).font(.callout.monospaced())
                Spacer()
                Button("Remove \(item)", systemImage: "minus.circle") {
                    save(AgentRulesUpdate(preApproved: [category: list.filter { $0 != item }]))
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.failed)
            }
        }
        HStack {
            TextField("Add", text: entry(category), prompt: Text(verbatim: "flytap.com or someone@example.com"))
                .font(.callout.monospaced())
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                #endif
                .onSubmit { add(category) }
            Button("Add") { add(category) }
                .buttonStyle(.borderless)
                .disabled(entries[category, default: ""].trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if showingTrouble, let trouble { troubleText(trouble) }
    }

    #if os(macOS)
    /// MacSettings' left column: a matrix of white rows on the ground under the level words, the
    /// locked row, then the pre-approved list folded into one line with its editor a popover away.
    private var boardBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Rules").font(.system(size: 18, weight: .bold, design: .rounded))
                Text("What \(agent.title) may do on its own. Ask first lands in Needs you.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
            if let rules {
                // Gone with the tracks: a row too narrow for one falls back to its menu.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text("Action").frame(idealWidth: labelWidth, maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 4) {
                            ForEach(RuleLevel.ladder, id: \.self) { level in
                                Text(level == .ifPreApproved ? "Pre-approved" : level.word).frame(maxWidth: .infinity)
                            }
                        }
                        .frame(width: Self.trackWidth)
                    }
                    Color.clear.frame(height: 0)
                }
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.44)
                .textCase(.uppercase)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 14)
                .accessibilityHidden(true)

                VStack(spacing: 5) {
                    ForEach(RuleRow.editable(runsAs: agent.name)) { row in
                        levelRow(row, rules: rules).boardRow()
                    }
                    lockedRow.boardRow()
                }
                ForEach(listed(rules)) { row in preApprovedStrip(rules, row) }
                if let trouble { troubleText(trouble) }
            } else if let trouble {
                troubleText(trouble)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(Theme.ink)
    }

    private func preApprovedStrip(_ rules: AgentRules, _ row: RuleRow) -> some View {
        let palette = looks[agent.name].palette(dark: scheme == .dark)
        let entries = rules.preApproved[row.category] ?? []
        let list = entries.isEmpty ? "nothing yet" : entries.joined(separator: ", ")
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.shield").foregroundStyle(palette.accentText.color)
            Text("**\(row.name), pre-approved:** \(list)")
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Edit list") { editingList = row.category }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(palette.accentText.color)
                .popover(
                    isPresented: Binding(get: { editingList == row.category }, set: { editingList = $0 ? row.category : nil }),
                    arrowEdge: .bottom
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pre-approved: \(row.name)").font(.sectionTitle)
                        if let rules = self.rules { preApprovedRows(rules, row.category) }
                        preApprovedFooter
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(width: 360)
                }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(palette.soft.color, in: .rect(cornerRadius: 16))
    }

    private static let trackWidth: CGFloat = 400
    private var labelWidth: CGFloat { board ? 150 : 200 }
    #endif

    private func troubleText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.failed)
    }

    private func label(_ row: RuleRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.name)
            Text(row.hint)
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }

    private func color(_ level: RuleLevel) -> AnyShapeStyle {
        switch level {
        case .onItsOwn, .ifPreApproved: AnyShapeStyle(accent)
        case .askFirst: AnyShapeStyle(Theme.needsYou)
        case .handToYou: AnyShapeStyle(Theme.ink)
        case .other: AnyShapeStyle(Theme.muted)
        }
    }

    private func binding(_ row: RuleRow, _ rules: AgentRules) -> Binding<RuleLevel> {
        Binding(
            get: { rules.levels[row.category] ?? .other("unset") },
            set: { save(AgentRulesUpdate(levels: [row.category: $0])) }
        )
    }

    @ViewBuilder private func levelRow(_ row: RuleRow, rules: AgentRules) -> some View {
        let level = binding(row, rules)
        #if os(macOS)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                // An ideal width of its own, or a long hint alone would push its row to the menu.
                label(row).frame(idealWidth: labelWidth, maxWidth: .infinity, alignment: .leading)
                levelPills(row, level: level)
            }
            compactRow(row, level: level)
        }
        #else
        compactRow(row, level: level)
        #endif
    }

    #if os(macOS)
    /// The canvas's segmented control: a quiet track, the picked level filled in the agent's colour,
    /// or in ink where the agent hands it to you.
    private func levelPills(_ row: RuleRow, level: Binding<RuleLevel>) -> some View {
        let palette = looks[agent.name].palette(dark: scheme == .dark)
        return HStack(spacing: 4) {
            ForEach(RuleLevel.ladder, id: \.self) { option in
                let picked = level.wrappedValue == option
                let fill: AnyShapeStyle = !picked ? AnyShapeStyle(.clear)
                    : option == .handToYou ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(palette.bubble.color)
                let text: AnyShapeStyle = !picked ? AnyShapeStyle(Theme.secondary)
                    : option == .handToYou ? AnyShapeStyle(Theme.onInk) : AnyShapeStyle(palette.bubbleText.color)
                Button { level.wrappedValue = option } label: {
                    Text(option.short)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .foregroundStyle(text)
                        .background(fill, in: .rect(cornerRadius: 10))
                        .contentShape(.rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.word)
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(width: Self.trackWidth)
        .background(Theme.ink.opacity(0.05), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.name)
    }
    #endif

    private func compactRow(_ row: RuleRow, level: Binding<RuleLevel>) -> some View {
        // Side by side where it fits; a narrow inspector stacks the level under the name instead
        // of squeezing the name to a word a line.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                label(row).frame(idealWidth: 140, maxWidth: .infinity, alignment: .leading)
                levelMenu(row, level: level)
            }
            VStack(alignment: .leading, spacing: 6) {
                label(row)
                levelMenu(row, level: level)
            }
        }
    }

    private func levelMenu(_ row: RuleRow, level: Binding<RuleLevel>) -> some View {
        Menu {
            Picker(row.name, selection: level) {
                ForEach(RuleLevel.ladder, id: \.self) { Text($0.word).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(level.wrappedValue.word)
                    .fontWeight(.semibold)
                    .foregroundStyle(color(level.wrappedValue))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.muted)
            }
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("\(row.name): \(level.wrappedValue.word)")
    }

    @ViewBuilder private var lockedRow: some View {
        let sideBySide = HStack(spacing: 12) {
            label(RuleRow.locked)
            Spacer(minLength: 8)
            alwaysYours
        }
        .accessibilityElement(children: .combine)
        #if os(macOS)
        // Only on the Mac: in an iOS Form row this ViewThatFits sizes the row to 260pt and hides it.
        ViewThatFits(in: .horizontal) {
            sideBySide
            VStack(alignment: .leading, spacing: 6) {
                label(RuleRow.locked)
                alwaysYours
            }
            .accessibilityElement(children: .combine)
        }
        #else
        sideBySide
        #endif
    }

    private var alwaysYours: some View {
        Label("Always yours", systemImage: "lock.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(Theme.ink)
    }

    private func add(_ category: String) {
        let item = entries[category, default: ""].trimmingCharacters(in: .whitespaces).lowercased()
        guard let rules, !item.isEmpty else { return }
        save(AgentRulesUpdate(preApproved: [category: (rules.preApproved[category] ?? []) + [item]])) { entries[category] = "" }
    }

    private func load() async {
        do {
            rules = try await session.run { try await $0.rules(agent: agent.name) }
            trouble = nil
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }

    private func save(_ update: AgentRulesUpdate, then saved: @escaping () -> Void = {}) {
        trouble = nil
        Task {
            do {
                rules = try await session.run { try await $0.setRules(agent: agent.name, update) }
                saved()
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
        }
    }
}

#if os(macOS)
private extension View {
    func boardRow() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.card, in: .rect(cornerRadius: 16))
    }
}
#endif

/// How many rule rows sit at each level, loosest first: "5 on its own · 3 ask first".
func rulesSummary(_ levels: [String: RuleLevel]) -> String {
    let rows = RuleRow.editable(runsAs: "").compactMap { levels[$0.category] }
    return RuleLevel.ladder
        .map { level in (level, rows.filter { $0 == level }.count) }
        .filter { $0.1 > 0 }
        .map { "\($0.1) \($0.0.word.lowercased())" }
        .joined(separator: " · ")
}
