import RegexBuilder
import SwiftUI

/// What a reply is made of: prose, and the fenced code blocks in it. Fences are the one block
/// construct SwiftUI's inline markdown cannot carry, and the one an agent's reply is full of.
enum MarkdownBlock: Equatable {
    case prose(String)
    case code(language: String, text: String)
    case file(String)
}

/// Splits on ``` fences. An unclosed fence runs to the end, which is what a reply still being
/// streamed looks like.
func markdownBlocks(_ content: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var prose: [Substring] = []
    var code: [Substring] = []
    var language = ""
    var inCode = false

    func flushProse() {
        let text = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
        if !text.isEmpty { blocks.append(.prose(text)) }
        prose = []
    }

    for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            if inCode {
                blocks.append(.code(language: language, text: code.joined(separator: "\n")))
                code = []
                inCode = false
            } else {
                flushProse()
                language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                inCode = true
            }
            continue
        }
        if inCode {
            code.append(line)
        } else if let path = standaloneFile(line) {
            flushProse()
            blocks.append(.file(path))
        } else {
            prose.append(line)
        }
    }
    if inCode {
        blocks.append(.code(language: language, text: code.joined(separator: "\n")))
    } else {
        flushProse()
    }
    return blocks
}

private let quotedFilePath = Regex { ChoiceOf { Regex { "`"; Capture { filePath }; "`" }; Capture { filePath } } }

/// With `linkingFiles`, a path in a sentence becomes a link named after the file, the way a chat
/// app shows an attachment it mentions in passing. Backticks around it go: a link cannot live in code.
func linkingFiles(_ prose: String) -> String {
    prose.replacing(quotedFilePath) { match in
        let path = String(match.1 ?? match.2 ?? "")
        guard let link = fileLink(path) else { return path }
        return "[\((path as NSString).lastPathComponent)](\(link.absoluteString))"
    }
}

struct MarkdownListItem: Equatable {
    var marker: String
    var blocks: [MarkdownNode]
}

indirect enum MarkdownNode: Equatable {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    case list([MarkdownListItem])
    case quote([MarkdownNode])
    /// The first row is the header. Every row has a cell per column, empty where the source had none.
    case table(alignments: [PresentationIntent.TableColumn.Alignment], rows: [[AttributedString]])
    case code(language: String, text: String)
    case rule
}

/// CommonMark reads a single newline as a space, but an agent writes one to start a new line, so
/// every line ends in the two spaces that make it a hard break. Table rows ignore them. GFM also
/// reads a line straight after a table as one more row, so a blank line ends the table there.
private func hardBreaks(_ prose: String) -> String {
    let lines = prose.split(separator: "\n", omittingEmptySubsequences: false)
    func isRow(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") || trimmed.hasSuffix("|")
    }
    var out: [String] = []
    for (index, line) in lines.enumerated() {
        let blank = line.allSatisfy(\.isWhitespace)
        if !blank, index > 0, isRow(lines[index - 1]), !isRow(line) { out.append("") }
        out.append(blank ? String(line) : line + "  ")
    }
    return out.joined(separator: "\n")
}

private final class Draft {
    let intent: PresentationIntent.IntentType?
    var children: [Draft] = []
    var text = AttributedString()
    init(_ intent: PresentationIntent.IntentType?) { self.intent = intent }
}

/// A prose chunk's blocks, from Foundation's own CommonMark and GFM parser: each run carries the
/// stack of blocks it sits in, so runs sharing a block's identity are that block's contents.
func markdownNodes(_ prose: String, linkingFiles linking: Bool = false) -> [MarkdownNode] {
    let source = hardBreaks(linking ? linkingFiles(prose) : prose)
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
    )
    guard let parsed = try? AttributedString(markdown: source, options: options) else {
        return [.paragraph(AttributedString(prose))]
    }
    let root = Draft(nil)
    for run in parsed.runs {
        var draft = root
        let path = (run.presentationIntent?.components ?? []).reversed()
        if path.isEmpty {
            if root.children.last?.intent != nil || root.children.isEmpty { root.children.append(Draft(nil)) }
            draft = root.children[root.children.count - 1]
        }
        for intent in path {
            if let last = draft.children.last, last.intent?.identity == intent.identity {
                draft = last
            } else {
                let next = Draft(intent)
                draft.children.append(next)
                draft = next
            }
        }
        draft.text.append(parsed[run.range])
    }
    return root.children.flatMap(nodes)
}

private func nodes(_ draft: Draft) -> [MarkdownNode] {
    switch draft.intent?.kind {
    case .header(let level):
        return [.heading(level: level, draft.text)]
    case .codeBlock(let language):
        let text = String(draft.text.characters)
        return [.code(language: language ?? "", text: text.hasSuffix("\n") ? String(text.dropLast()) : text)]
    case .thematicBreak:
        return [.rule]
    case .blockQuote:
        return [.quote(draft.children.flatMap(nodes))]
    case .orderedList, .unorderedList:
        let ordered = draft.intent?.kind == .orderedList
        return [.list(draft.children.enumerated().map { index, item in
            listItem(item, marker: ordered ? "\(ordinal(item) ?? index + 1)." : "•")
        })]
    case .table(let columns):
        let rows = draft.children.map { row in
            var cells = Array(repeating: AttributedString(), count: columns.count)
            for cell in row.children {
                if case .tableCell(let column) = cell.intent?.kind, cells.indices.contains(column) {
                    cells[column] = cell.text
                }
            }
            return cells
        }
        return [.table(alignments: columns.map(\.alignment), rows: rows)]
    default:
        return draft.children.isEmpty ? [.paragraph(draft.text)] : draft.children.flatMap(nodes)
    }
}

private func ordinal(_ item: Draft) -> Int? {
    if case .listItem(let ordinal) = item.intent?.kind { return ordinal }
    return nil
}

/// Foundation has no task lists, so `[ ]` and `[x]` at the head of an item become its marker.
private func listItem(_ item: Draft, marker: String) -> MarkdownListItem {
    var blocks = item.children.flatMap(nodes)
    guard case .paragraph(let text) = blocks.first else { return MarkdownListItem(marker: marker, blocks: blocks) }
    let head = String(text.characters.prefix(4))
    guard let box = ["[ ] ": "☐", "[x] ": "☑", "[X] ": "☑"][head] else {
        return MarkdownListItem(marker: marker, blocks: blocks)
    }
    blocks[0] = .paragraph(AttributedString(text[text.index(text.startIndex, offsetByCharacters: 4)...]))
    return MarkdownListItem(marker: box, blocks: blocks)
}

/// A reply drawn as its blocks: prose as full markdown, code in a box with a copy button, and
/// the files it names as cards where they are named. Without `files` a path is only text.
struct MarkdownText: View {
    let content: String
    var files: FileSource?

    @State private var previewing: URL?
    @State private var trouble: String?
    @Environment(Artifacts.self) private var artifacts: Artifacts?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdownBlocks(content).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let text):
                    MarkdownBlocks(nodes: markdownNodes(text, linkingFiles: files != nil))
                case .code(let language, let text):
                    CodeBlock(language: language, text: text)
                case .file(let path):
                    if let files {
                        FileCard(source: files, path: path)
                    } else {
                        Text(path).font(.callout.monospaced())
                    }
                }
            }
            if let trouble {
                Text(trouble).font(.caption).foregroundStyle(.red)
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard let files, let path = linkedFile(url) else { return .systemAction }
            if artifacts?.show(path, from: files) == true { return .handled }
            Task {
                do {
                    previewing = try await files.fetch(path)
                    trouble = nil
                } catch {
                    trouble = "\(error.localizedDescription): \(path)"
                }
            }
            return .handled
        })
        .quickLookPreview($previewing)
    }
}

struct MarkdownBlocks: View {
    let nodes: [MarkdownNode]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                MarkdownNodeView(node: node)
            }
        }
    }
}

struct MarkdownNodeView: View {
    let node: MarkdownNode

    var body: some View {
        switch node {
        case .paragraph(let text):
            Text(text)
        case .heading(let level, let text):
            Text(text).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).monospacedDigit().foregroundStyle(.secondary)
                        MarkdownBlocks(nodes: item.blocks)
                    }
                }
            }
        case .quote(let blocks):
            MarkdownBlocks(nodes: blocks)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Capsule().fill(.tertiary).frame(width: 3) }
        case .table(let alignments, let rows):
            MarkdownTable(alignments: alignments, rows: rows)
        case .code(let language, let text):
            CodeBlock(language: language, text: text)
        case .rule:
            Divider()
        }
    }
}

struct MarkdownTable: View {
    let alignments: [PresentationIntent.TableColumn.Alignment]
    let rows: [[AttributedString]]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) { grid }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        Text(cell)
                            .fontWeight(index == 0 ? .semibold : nil)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .gridColumnAlignment(alignment(column))
                    }
                }
            }
        }
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        switch alignments.indices.contains(column) ? alignments[column] : .left {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }
}

struct CodeBlock: View {
    let language: String
    let text: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    copyToPasteboard(text)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal) {
                Text(text)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(.background.opacity(0.5), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

func copyToPasteboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}

func copyImageToPasteboard(at url: URL) {
    #if os(macOS)
    guard let image = NSImage(contentsOf: url) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
    #else
    UIPasteboard.general.image = UIImage(contentsOfFile: url.path)
    #endif
}

/// Built when a share asks for it rather than on every redraw of the view holding the link.
struct ThreadExport: Transferable {
    let messages: [Message]
    let title: String
    let titles: [String: String]

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { exportMarkdown($0.messages, title: $0.title, titles: $0.titles) }
    }
}

/// A thread as a Markdown document, for sharing or keeping. Tool traffic is folded to one line
/// per call; screenshots are named, not embedded.
nonisolated func exportMarkdown(_ messages: [Message], title: String, titles: [String: String]) -> String {
    var out = ["# \(title)", ""]
    for message in messages {
        let when = Date(timeIntervalSince1970: Double(message.createdAt) / 1000)
            .formatted(date: .abbreviated, time: .shortened)
        switch message.role {
        case .user:
            let who = message.sender.map { titles[$0] ?? $0 } ?? "You"
            out.append("**\(who)** · \(when)")
            out.append("")
            out.append(message.content)
        case .assistant:
            let who = message.sender.map { titles[$0] ?? $0 } ?? "Agent"
            out.append("**\(who)** · \(when)")
            out.append("")
            if !message.content.isEmpty { out.append(message.content) }
            for call in message.toolCalls ?? [] {
                out.append("- `\(call.name)` \(call.arguments)")
            }
        case .tool:
            if message.image != nil { out.append("- screenshot") }
            if !message.content.isEmpty {
                out.append("```")
                out.append(message.content)
                out.append("```")
            }
        }
        out.append("")
    }
    return out.joined(separator: "\n")
}
