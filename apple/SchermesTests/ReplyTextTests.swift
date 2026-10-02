import SwiftUI
import Testing
@testable import Schermes

private let reply = """
Gevonden, en het is reproduceerbaar.

**De fout:** `INSTALLERS[command]?.includes is not a function`

De harness kijkt naar het **eerste woord**.
Ik heb het geïsoleerd:

```
hello         ok
valueOf       THROWS
```

- een
- twee
"""

private func document(_ content: String) -> NSAttributedString {
    replyDocument(
        bubbleChunks(content),
        linkingFiles: false,
        style: ReplyStyle(font: .systemFont(ofSize: 13), ink: .black, muted: .gray)
    )
}

@Test func everyParagraphKnowsItsBubble() {
    let text = document(reply)
    var bubbles: [Int] = []
    text.enumerateAttribute(.replyBubble, in: NSRange(location: 0, length: text.length)) { value, _, _ in
        if let bubble = value as? Int, bubbles.last != bubble { bubbles.append(bubble) }
    }
    #expect(bubbles == Array(0..<bubbleChunks(reply).count))
}

@Test func aCopyAcrossBubblesReadsAsTheAgentWroteIt() {
    #expect(replyCopy(document(reply)) == """
    Gevonden, en het is reproduceerbaar.

    De fout: INSTALLERS[command]?.includes is not a function

    De harness kijkt naar het eerste woord.
    Ik heb het geïsoleerd:

    hello         ok
    valueOf       THROWS

    • een
    • twee
    """)
}

@Test func aFileOnItsOwnBreaksTheTextForItsCard() {
    #expect(replySegments(["Klaar.", "Hier:\n~/workspace/report.xlsx", "Nog iets?"]) == [
        .text(["Klaar.", "Hier:"]), .file("~/workspace/report.xlsx"), .text(["Nog iets?"]),
    ])
}

@MainActor @Test func copyingASelectionAcrossBubblesInTheTextView() {
    let (storage, container) = textKit2Stack()
    let view = BubbleTextView(frame: .zero, textContainer: container)
    view.storage = storage
    let content = BubbleContent(chunks: ["Gelukt.", "De functie `x` werkt.", "```\na\nb\n```"], linking: false, dark: false, typeSize: .large)
    #if os(macOS)
    view.textStorage?.setAttributedString(content.document())
    #else
    view.attributedText = content.document()
    #endif
    let size = view.fit(width: 400)
    #expect(size.width > 0 && size.width <= 352 && size.height > 0)
    let whole = NSRange(location: 2, length: content.document().length - 2)
    #if os(macOS)
    view.setSelectedRange(whole)
    view.copy(nil)
    #expect(NSPasteboard.general.string(forType: .string) == "lukt.\n\nDe functie x werkt.\n\na\nb")
    #else
    view.selectedRange = whole
    view.copy(nil)
    #expect(UIPasteboard.general.string == "lukt.\n\nDe functie x werkt.\n\na\nb")
    #endif
}
