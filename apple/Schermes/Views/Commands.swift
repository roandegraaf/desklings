import SwiftUI

/// What the owner can do from the composer by typing a slash, the way a Telegram bot lists its
/// commands: `/` opens the list, a few letters narrow it, Return runs the one picked. Nothing here
/// is new to the thread — every command is a button or a page it already has — this is the
/// keyboard's way to them, and the one place they are all named at once.
enum SlashCommand: String, CaseIterable, Identifiable {
    case new, compact, stop, retry, undo, remember, interview, screen, profile, routines, activity, memory

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .new: "Clear this thread and start over"
        case .compact: "Fold the thread so far into a summary"
        case .stop: "Stop the turn in progress"
        case .retry: "Ask the last message again"
        case .undo: "Take your last message back"
        case .remember: "Add a note to lasting memory"
        case .interview: "Have the agent interview you about its role"
        case .screen: "Open the agent's screen"
        case .profile: "Open the profile"
        case .routines: "Open the routines"
        case .activity: "Open the activity log"
        case .memory: "Open the memory files"
        }
    }

    /// What follows the command, for the one that takes something.
    var argument: String? { self == .remember ? "note" : nil }

    /// A shared thread has no single agent whose screen, memory or role it is.
    var sharedToo: Bool {
        switch self {
        case .new, .compact, .stop, .retry, .undo: true
        default: false
        }
    }

    /// A task worker has no composer, so it has no commands either.
    static func offered(in thread: ChatThread) -> [SlashCommand] {
        if thread.isWorker { return [] }
        return thread.only == nil ? allCases.filter(\.sharedToo) : allCases
    }
}

/// The commands a draft is on its way to naming: a slash, part of a name and nothing after it.
/// `/` alone lists them all; a space or a newline means the owner is past the command. Matched
/// without case, because an iPhone capitalises the first letter of anything typed.
func commandMatches(_ draft: String, in thread: ChatThread) -> [SlashCommand] {
    guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return [] }
    let typed = draft.dropFirst().lowercased()
    return SlashCommand.offered(in: thread).filter { $0.rawValue.hasPrefix(typed) }
}

/// The command a message is, and what follows it. Only a whole name counts: `/home/agent-x/…`
/// is a path, and anything that is not exactly a command goes to the agent as written.
func parseCommand(_ text: String, in thread: ChatThread) -> (command: SlashCommand, argument: String)? {
    guard text.hasPrefix("/") else { return nil }
    let head = text.dropFirst().prefix { !$0.isWhitespace }
    guard let command = SlashCommand.offered(in: thread).first(where: { $0.rawValue == head.lowercased() })
    else { return nil }
    let argument = text.dropFirst(head.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
    return (command, argument)
}

/// What `/compact` did, in words. Per agent in a shared thread, because each folds its own view.
func compactionNotice(_ result: CompactResult, titles: [String: String]) -> String {
    let folded = result.compacted.filter { $0.value > 0 }
    if folded.isEmpty { return "Nothing new to fold in since the last summary." }
    if result.compacted.count == 1, let count = folded.first?.value {
        return "Folded \(count) message\(count == 1 ? "" : "s") into a summary."
    }
    let parts = folded.keys.sorted().map { "\(titles[$0] ?? $0) (\(folded[$0]!))" }
    return "Folded into a summary for " + parts.joined(separator: ", ") + "."
}

/// `MEMORY.md` with the note as its last line, written the way the agent's own `remember` writes
/// one: a list item, on one line whatever the owner typed.
func withNote(_ lasting: String, _ note: String) -> String {
    let line = "- " + note.split(whereSeparator: \.isNewline).joined(separator: " ")
    let body = lasting.trimmingCharacters(in: .whitespacesAndNewlines)
    return (body.isEmpty ? line : body + "\n" + line) + "\n"
}

/// The list above the composer while a command is being typed. The picked row is what Return
/// runs, the arrows move it and Tab completes it; every row also answers a tap.
struct CommandPalette: View {
    let commands: [SlashCommand]
    let picked: SlashCommand?
    let pick: (SlashCommand) -> Void

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(commands) { command in
                        Button { pick(command) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("/" + command.rawValue)
                                    .font(.body.monospaced().weight(.semibold))
                                if let argument = command.argument {
                                    Text("<\(argument)>")
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.tertiary)
                                }
                                Text(command.summary)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                command == picked ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear),
                                in: .rect(cornerRadius: 10)
                            )
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("/\(command.rawValue), \(command.summary)")
                        .id(command)
                    }
                }
                .padding(6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, 240))
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: picked, initial: true) { _, now in
                if let now { reader.scrollTo(now) }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
