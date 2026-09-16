import Foundation
import Testing
@testable import Schermes

@Test func fencesSplitProseFromCodeAndAnUnclosedFenceRunsToTheEnd() {
    let blocks = markdownBlocks("Run this:\n```sh\nls -la\n```\nthen stop\n```\npartial")
    #expect(blocks == [
        .prose("Run this:"),
        .code(language: "sh", text: "ls -la"),
        .prose("then stop"),
        .code(language: "", text: "partial"),
    ])
}

@Test func plainTextIsOneProseBlockAndBlankTextIsNone() {
    #expect(markdownBlocks("hello") == [.prose("hello")])
    #expect(markdownBlocks("\n\n") == [])
}

private func text(_ string: AttributedString) -> String { String(string.characters) }

@Test func proseIsFullMarkdownAndASingleNewlineStillStartsALine() {
    let nodes = markdownNodes("""
    ## Plan
    first line
    second **line**

    3. three
    4. four
       - nested
    - [ ] open
    - [x] done
    > quoted
    ---
    """)
    #expect(nodes.count == 6)
    guard case .heading(2, let heading) = nodes[0] else { Issue.record("no heading"); return }
    #expect(text(heading) == "Plan")
    guard case .paragraph(let lines) = nodes[1] else { Issue.record("no paragraph"); return }
    #expect(text(lines) == "first line\nsecond line")
    guard case .list(let ordered) = nodes[2] else { Issue.record("no ordered list"); return }
    #expect(ordered.map(\.marker) == ["3.", "4."])
    guard case .list(let nested) = ordered[1].blocks.last else { Issue.record("no nested list"); return }
    #expect(nested.map(\.marker) == ["•"])
    guard case .list(let tasks) = nodes[3] else { Issue.record("no task list"); return }
    #expect(tasks.map(\.marker) == ["☐", "☑"])
    #expect(tasks[1].blocks.count == 1)
    if case .paragraph(let done) = tasks[1].blocks[0] { #expect(text(done) == "done") }
    guard case .quote(let quoted) = nodes[4] else { Issue.record("no quote"); return }
    #expect(quoted.count == 1)
    #expect(nodes[5] == .rule)
}

@Test func aTableRightUnderALineKeepsItsColumnsAndFillsEmptyCells() {
    let nodes = markdownNodes("""
    Sheet 1 — "Sales"
    | Region | Q1 | Share |
    |---|--:|:-:|
    | North | 12,450 | 17.9% |
    | **Total** | 75,280 | |
    """)
    #expect(nodes.count == 2)
    guard case .table(let alignments, let rows) = nodes[1] else { Issue.record("no table"); return }
    #expect(alignments == [.left, .right, .center])
    #expect(rows.map { $0.map(text) } == [
        ["Region", "Q1", "Share"],
        ["North", "12,450", "17.9%"],
        ["Total", "75,280", ""],
    ])
    #expect(rows[2][0].runs.first?.inlinePresentationIntent == .stronglyEmphasized)
}

@Test func aLineStraightAfterATableIsProseAgain() {
    let nodes = markdownNodes("| A | B |\n|---|---|\n| 1 | 2 |\nSheet 2 is next\nand so is this")
    #expect(nodes.count == 2)
    guard case .table(_, let rows) = nodes[0], case .paragraph(let after) = nodes[1] else {
        Issue.record("not a table and a paragraph"); return
    }
    #expect(rows.count == 2)
    #expect(text(after) == "Sheet 2 is next\nand so is this")
}

@Test func aFileOnALineOfItsOwnIsDrawnWhereItIsNamedAndOneInASentenceIsALink() {
    let reply = """
    Ja — de Excel-sheet staat klaar:

    **~/workspace/marktplaats_furby.xlsx**

    De ruwe data staat ook in `~/workspace/data.csv`, en het verslag in /home/agent-scout/out/rapport.final.pdf.
    - `~/workspace/chart.png`
    Not a folder like ~/workspace/ or https://example.com/a.html.
    """
    let blocks = markdownBlocks(reply)
    #expect(blocks.count == 5)
    #expect(blocks[0] == .prose("Ja — de Excel-sheet staat klaar:"))
    #expect(blocks[1] == .file("~/workspace/marktplaats_furby.xlsx"))
    #expect(blocks[3] == .file("~/workspace/chart.png"))
    #expect(blocks[4] == .prose("Not a folder like ~/workspace/ or https://example.com/a.html."))

    guard case .prose(let sentence) = blocks[2] else { Issue.record("no sentence"); return }
    guard case .paragraph(let linked) = markdownNodes(sentence, linkingFiles: true).first,
          case .paragraph(let plain) = markdownNodes(sentence).first
    else { Issue.record("no paragraph"); return }
    #expect(text(linked) == "De ruwe data staat ook in data.csv, en het verslag in rapport.final.pdf.")
    let targets = linked.runs.compactMap { $0.link.flatMap(linkedFile) }
    #expect(targets == ["~/workspace/data.csv", "/home/agent-scout/out/rapport.final.pdf"])
    #expect(text(plain).contains("~/workspace/data.csv"))
}

@Test func aFileIsNamedForWhatItIs() {
    #expect(fileKind("~/a.xlsx").label == "Spreadsheet")
    #expect(fileKind("~/a.csv").label == "Spreadsheet")
    #expect(fileKind("~/a.pdf").label == "PDF")
    #expect(fileKind("~/a.png").label == "Image")
    #expect(fileKind("~/a.md").label == "Document")
    #expect(fileKind("~/a.py").label == "Code")
    #expect(fileKind("~/a.zzqq").label == "File")
}

@Test func textThatIsNotMarkdownComesBackAsItself() {
    let odd = "a < b && c > d [x](y"
    guard case .paragraph(let parsed) = markdownNodes(odd).first else { Issue.record("no paragraph"); return }
    #expect(text(parsed) == odd)
}

@Test func exportNamesEveryoneAndFoldsToolTraffic() {
    let messages = [
        Message(id: 1, role: .user, content: "hi", createdAt: 0),
        Message(id: 2, role: .assistant, content: "", sender: "alpha",
                toolCalls: [ToolCall(id: "c1", name: "run_command", arguments: "{}")], createdAt: 0),
        Message(id: 3, role: .tool, content: "out", sender: "alpha", toolCallId: "c1",
                image: Base64Image(mediaType: "image/png", base64: "AAA"), createdAt: 0),
        Message(id: 4, role: .assistant, content: "done", sender: "alpha", createdAt: 0),
    ]
    let doc = exportMarkdown(messages, title: "Al", titles: ["alpha": "Al"])
    #expect(doc.hasPrefix("# Al\n"))
    #expect(doc.contains("**You**"))
    #expect(doc.contains("**Al**"))
    #expect(doc.contains("- `run_command` {}"))
    #expect(doc.contains("- screenshot"))
    #expect(doc.contains("```\nout\n```"))
    #expect(!doc.contains("AAA"), "screenshot bytes never land in the export")
}

@Test func aLookRoundTripsThroughItsTokenAndAnUnknownTokenIsRefused() {
    let look = BloubIdentity(shape: .cloud, color: .teal)
    #expect(look.token == "cloud:teal")
    #expect(BloubIdentity(token: "cloud:teal") == look)
    #expect(BloubIdentity(token: "cloud") == nil)
    #expect(BloubIdentity(token: "cloud:mauve") == nil)
    #expect(BloubIdentity(token: "blob:teal") == nil)
}

@Test func adoptingLooksFromTheDaemonWinsOverTheLocalCopyAndSkipsWhatItCannotRead() {
    let defaults = UserDefaults(suiteName: "MarkdownTests.\(UUID())")!
    let looks = AgentLooks(defaults: defaults)
    looks["alpha"] = BloubIdentity(shape: .circle, color: .red)
    let alpha = Agent(id: 1, name: "alpha", look: "hexagon:blue", display: 1, state: .idle, createdAt: 0)
    let bravo = Agent(id: 2, name: "bravo", look: "nope", display: 2, state: .idle, createdAt: 0)
    let charlie = Agent(id: 3, name: "charlie", display: 3, state: .idle, createdAt: 0)
    looks.adopt([alpha, bravo, charlie])
    #expect(looks["alpha"] == BloubIdentity(shape: .hexagon, color: .blue))
    #expect(looks["bravo"] == .standard(for: "bravo"))
    #expect(looks["charlie"] == .standard(for: "charlie"))
}

@Test func aStopAndATurnReadAsSentences() {
    let stop = ExecutionEvent(id: 1, type: .stop, data: [:], createdAt: 0)
    #expect(sentence(for: stop) == "You stopped it")
    let plain = ExecutionEvent(id: 2, type: .turn, data: ["steps": .number(3)], createdAt: 0)
    #expect(sentence(for: plain) == "Finished a turn of 3 model calls")
    let metered = ExecutionEvent(
        id: 3, type: .turn,
        data: ["steps": .number(1), "promptTokens": .number(12345), "completionTokens": .number(80)],
        createdAt: 0
    )
    #expect(sentence(for: metered) == "Finished a turn of 1 model call: 12.3k tokens in, 80 tokens out")
}

@Test func aPreviewDropsTheMarksAndFoldsTheLines() {
    #expect(plainPreview("## Plan\n\nHere is **bold** and `code`.\n\n- one\n- two\n```sh\nls\n```") == "Plan Here is bold and code. one two ls")
}


@Test func onlyWhatTheAppCanDrawBecomesAnArtifact() {
    #expect(artifactKind("~/notes/README.md") == .markdown)
    #expect(artifactKind("~/site/index.html") == .web(mime: "text/html"))
    #expect(artifactKind("~/chart.svg") == .web(mime: "image/svg+xml"))
    #expect(artifactKind("~/app.py") == .code)
    #expect(artifactKind("~/log.txt") == .code)
    #expect(artifactKind("~/report.pdf") == nil)
    #expect(artifactKind("~/data.csv") == nil)
    #expect(artifactKind("~/photo.png") == nil)
}
