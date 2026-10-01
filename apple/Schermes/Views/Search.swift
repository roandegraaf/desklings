import SwiftUI

extension SearchResult {
    /// An agent's own thread is reached through the agent; every other one by its id.
    var thread: ThreadSource? {
        guard let conversationId else { return nil }
        if let participants, participants.count == 1, let only = participants.first { return .agent(only) }
        return .conversation(conversationId)
    }

    var kindWord: (symbol: String, word: String) {
        switch kind {
        case .message: ("bubble.left", "Message")
        case .screenshot: ("camera", "Screenshot")
        case .file: (fileKind(path ?? "").symbol, fileKind(path ?? "").label)
        case .other(let raw): ("magnifyingglass", raw.capitalized)
        }
    }
}

/// What the question was read as, one chip per line of the daemon's, and a quiet note when no
/// model read it.
struct UnderstoodAs: View {
    let answer: SearchAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Understood as")
                    .font(.canvas(12, .caption))
                    .foregroundStyle(Theme.muted)
                FlowChips(lines: answer.understoodAs)
            }
            if !answer.byModel {
                Text("Plain text search")
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

private struct FlowChips: View {
    let lines: [String]

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 4) { chips }
        }
    }

    private var chips: some View {
        let amber = AgentPalette(BloubColorId.amber, dark: scheme == .dark)
        return ForEach(lines, id: \.self) { line in
            Text(line)
                .font(.canvas(12, .caption, weight: .bold))
                .foregroundStyle(amber.softText.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(amber.soft.color, in: .rect(cornerRadius: 10))
        }
    }
}

/// One hit and where it came from: what it is, whose it is, which thread or which path, when. The
/// best hit sits on the amber fill, larger.
struct ResultRow: View {
    let result: SearchResult
    let titles: [String: String]
    var top = false

    @Environment(AgentLooks.self) private var looks
    @Environment(\.colorScheme) private var scheme

    private var place: String? {
        switch result.kind {
        case .file: return nil
        default:
            guard let participants = result.participants, !participants.isEmpty else { return nil }
            return "in " + participants.map { titles[$0] ?? $0 }.formatted(.list(type: .and))
        }
    }

    private var headline: String {
        switch result.kind {
        case .file: (result.path.map { ($0 as NSString).lastPathComponent }).flatMap { $0.isEmpty ? nil : $0 } ?? result.kindWord.word
        case .message: result.snippet.isEmpty ? result.kindWord.word : "\u{201C}\(result.snippet)\u{201D}"
        default: result.snippet.isEmpty ? result.kindWord.word : result.snippet
        }
    }

    private var who: String { result.agent.map { titles[$0] ?? $0 } ?? "You" }

    private var tile: (fill: AnyShapeStyle, text: AnyShapeStyle) {
        let color: BloubColorId? = switch result.kind {
        case .file: fileKind(result.path ?? "").tint
        case .message: BloubColorId.amber
        default: nil
        }
        guard let color else { return (AnyShapeStyle(Theme.ink.opacity(0.06)), AnyShapeStyle(Theme.secondary)) }
        let palette = AgentPalette(color, dark: scheme == .dark)
        return (AnyShapeStyle(palette.soft.color), AnyShapeStyle(palette.softText.color))
    }

    var body: some View {
        HStack(alignment: top ? .top : .center, spacing: 12) {
            let tile = tile
            Image(systemName: result.kindWord.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tile.text)
                .frame(width: 32, height: 32)
                .background(tile.fill, in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: top ? 5 : 1) {
                Text(headline)
                    .font(top ? .canvas(16, .callout, weight: .bold) : .canvas(14, .subheadline, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let agent = result.agent {
                        BloubView(state: .idle, identity: looks[agent], size: 16)
                    }
                    Text([result.kindWord.word, who, place].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                }
                .font(.canvas(12, .caption))
                .foregroundStyle(Theme.muted)
                if result.kind == .file, let path = result.path {
                    Text(path)
                        .font(.canvas(12, .caption).monospaced())
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if top, !result.snippet.isEmpty, result.kind != .message {
                    Text(result.snippet)
                        .font(.canvas(13, .footnote))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 4)
            Text(shortTime(result.at))
                .font(.canvas(12, .caption))
                .foregroundStyle(Theme.muted)
        }
        .padding(top ? 14 : 0)
        .padding(.vertical, top ? 0 : 9)
        .padding(.horizontal, top ? 0 : 8)
        .background(
            top ? AnyShapeStyle(AgentPalette(BloubColorId.amber, dark: scheme == .dark).soft.color) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 18)
        )
        .accessibilityElement(children: .combine)
    }
}

/// ⌘K: one field for a question, what it was read as, and the hits. Return asks; each ask is a
/// model call on the daemon, so typing alone asks nothing.
struct SearchPanel: View {
    let session: Session
    let titles: [String: String]
    let onOpen: (SearchResult) -> Void
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var selection: TextSelection?
    @State private var answer: SearchAnswer?
    @State private var asking = false
    @State private var trouble: String?
    @FocusState private var focused: Bool

    init(
        session: Session,
        titles: [String: String],
        start: String = "",
        onClose: (() -> Void)? = nil,
        onOpen: @escaping (SearchResult) -> Void
    ) {
        self.session = session
        self.titles = titles
        self.onOpen = onOpen
        self.onClose = onClose
        _question = State(initialValue: start)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.muted)
                TextField("Search or ask", text: $question, selection: $selection)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit { Task { await ask() } }
                if asking { ProgressView().controlSize(.small) }
                #if os(macOS)
                Text("esc")
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(Theme.muted)
                #endif
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let trouble {
                        Text(trouble).font(.callout).foregroundStyle(Theme.failed)
                    }
                    if let answer {
                        UnderstoodAs(answer: answer)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 8)
                        if answer.hits.isEmpty {
                            Text("Nothing found.").foregroundStyle(Theme.muted).padding(.horizontal, 6)
                        }
                        ForEach(Array(answer.hits.enumerated()), id: \.element.id) { index, hit in
                            if index == 1 {
                                SidebarLabel(title: "Also close").padding(.horizontal, 6)
                            }
                            Button {
                                onOpen(hit)
                                close()
                            } label: {
                                ResultRow(result: hit, titles: titles, top: index == 0).contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Searches every thread, every agent's files and the text in their screenshots. Runs on your server.")
                .font(.canvas(12, .caption))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .background(Theme.panel)
        #if os(iOS)
        .presentationBackground(Theme.panel)
        #endif
        #if os(macOS)
        .frame(maxWidth: 720, maxHeight: 650)
        #endif
        .onAppear {
            focused = true
            // AppKit selects a field's whole text when it takes focus; put the caret back at the end.
            Task { @MainActor in selection = TextSelection(insertionPoint: question.endIndex) }
        }
        .task { if !question.isEmpty { await ask() } }
        #if os(macOS)
        .onExitCommand { close() }
        #endif
    }

    private func ask() async {
        let wanted = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !asking else { return }
        asking = true
        defer { asking = false }
        do {
            answer = try await session.run { try await $0.ask(wanted) }
            trouble = nil
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }
}

#if os(macOS)
/// MacSearch: the panel floats 100pt from the top of a dimmed console, and a click outside shuts it.
struct SearchOverlay<Panel: View>: View {
    let close: () -> Void
    @ViewBuilder let panel: Panel

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(scheme == .dark ? 0.5 : 0.4)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            panel
                .clipShape(.rect(cornerRadius: 26, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.35), radius: 40, y: 30)
                .padding(.top, 100)
                .padding([.horizontal, .bottom], 24)
                .accessibilityAddTraits(.isModal)
        }
        .transition(.opacity)
    }
}
#endif
