import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#endif

extension NSAttributedString.Key {
    static let replyBubble = NSAttributedString.Key("schermes.replyBubble")
    static let replyKind = NSAttributedString.Key("schermes.replyKind")
}

enum ReplyKind: String {
    case prose, code, quote, item
}

/// What the row offers on a reply, added to the text's own menu.
struct ReplyAction {
    let title: String
    let symbol: String
    let perform: () -> Void
}

enum ReplySegment: Equatable {
    case text([String])
    case file(String)
}

/// Bubbles in runs of selectable text, broken where a file stands on its own as a card.
func replySegments(_ chunks: [String]) -> [ReplySegment] {
    var out: [ReplySegment] = []
    var bubbles: [String] = []
    func close() {
        if !bubbles.isEmpty { out.append(.text(bubbles)) }
        bubbles = []
    }
    for chunk in chunks {
        var piece: [String] = []
        func flushPiece() {
            if !piece.isEmpty { bubbles.append(piece.joined(separator: "\n\n")) }
            piece = []
        }
        for block in markdownBlocks(chunk) {
            switch block {
            case .prose(let text): piece.append(text)
            case .code(let language, let text): piece.append("```\(language)\n\(text)\n```")
            case .file(let path):
                flushPiece()
                close()
                out.append(.file(path))
            }
        }
        flushPiece()
    }
    close()
    return out
}

// MARK: Document

struct ReplyStyle {
    var font: PlatformFont
    var ink: PlatformColor
    var muted: PlatformColor
}

let bubbleInset: CGFloat = 14
let bubblePadding: CGFloat = 10
let bubbleGap: CGFloat = 3
private let cardInset: CGFloat = 10
private let lineSeparator = "\u{2028}"

private struct Para {
    var text: NSMutableAttributedString
    var kind: ReplyKind
    var indent: CGFloat = 0
    var hanging: CGFloat = 0
}

/// A run of bubbles as one text. Each paragraph carries the bubble it belongs to, so the text view
/// can draw the bubble behind it and a copy can put the blank line back between two bubbles.
func replyDocument(_ chunks: [String], linkingFiles: Bool, style: ReplyStyle) -> NSAttributedString {
    let out = NSMutableAttributedString()
    for (bubble, chunk) in chunks.enumerated() {
        var paras: [Para] = []
        for block in markdownBlocks(chunk) {
            switch block {
            case .prose(let text):
                paras += markdownNodes(text, linkingFiles: linkingFiles).flatMap { paragraphs($0, style: style, indent: 0) }
            case .code(_, let text):
                paras.append(Para(text: mono(text, style), kind: .code))
            case .file(let path):
                paras.append(Para(text: NSMutableAttributedString(string: path, attributes: [.font: style.font, .foregroundColor: style.ink]), kind: .prose))
            }
        }
        for (index, para) in paras.enumerated() {
            let last = index == paras.count - 1
            let next = last ? nil : paras[index + 1]
            let paragraph = NSMutableParagraphStyle()
            let card: CGFloat = para.kind == .code ? cardInset : 0
            paragraph.firstLineHeadIndent = bubbleInset + para.indent + card
            paragraph.headIndent = bubbleInset + para.indent + para.hanging + card
            paragraph.tailIndent = -(bubbleInset + card)
            if para.hanging > 0 {
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
            }
            paragraph.paragraphSpacingBefore = card
            let between: CGFloat = last ? 2 * bubblePadding + bubbleGap : (para.kind == .item && next?.kind == .item ? 4 : 8)
            paragraph.paragraphSpacing = card + between
            let text = para.text
            let whole = NSRange(location: 0, length: text.length)
            text.addAttributes([.paragraphStyle: paragraph, .replyBubble: bubble, .replyKind: para.kind.rawValue], range: whole)
            if out.length > 0 {
                out.append(NSAttributedString(string: "\n", attributes: out.attributes(at: out.length - 1, effectiveRange: nil)))
            }
            out.append(text)
        }
    }
    return out
}

private func paragraphs(_ node: MarkdownNode, style: ReplyStyle, indent: CGFloat) -> [Para] {
    switch node {
    case .paragraph(let text):
        return [Para(text: inline(text, style: style), kind: .prose, indent: indent)]
    case .heading(let level, let text):
        let size = style.font.pointSize + (level == 1 ? 5 : level == 2 ? 3 : 1)
        return [Para(text: inline(text, style: style, font: weighted(style.font.withSize(size), bold: true)), kind: .prose, indent: indent)]
    case .list(let items):
        return items.flatMap { item -> [Para] in
            let marker = NSMutableAttributedString(
                string: item.marker + "\t",
                attributes: [.font: style.font.monospacedDigits, .foregroundColor: style.muted]
            )
            var blocks = item.blocks
            if case .paragraph(let text) = blocks.first {
                marker.append(inline(text, style: style))
                blocks.removeFirst()
            }
            let head = Para(text: marker, kind: .item, indent: indent, hanging: 20)
            return [head] + blocks.flatMap { paragraphs($0, style: style, indent: indent + 20) }
        }
    case .quote(let blocks):
        let muted = ReplyStyle(font: style.font, ink: style.muted, muted: style.muted)
        return blocks.flatMap { paragraphs($0, style: muted, indent: indent + 14) }.map {
            var para = $0
            para.kind = .quote
            return para
        }
    case .table(_, let rows):
        let cells = rows.map { $0.map { String($0.characters) } }
        let widths = (0..<(cells.first?.count ?? 0)).map { column in cells.map { $0[column].count }.max() ?? 0 }
        let text = NSMutableAttributedString()
        for (index, row) in cells.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: lineSeparator)) }
            let line = row.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "   ")
            let font = PlatformFont.monospacedSystemFont(ofSize: style.font.pointSize * 0.92, weight: index == 0 ? .semibold : .regular)
            text.append(NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: style.ink]))
        }
        return [Para(text: text, kind: .code, indent: indent)]
    case .code(_, let text):
        return [Para(text: mono(text, style), kind: .code, indent: indent)]
    case .rule:
        return []
    }
}

private func mono(_ text: String, _ style: ReplyStyle) -> NSMutableAttributedString {
    NSMutableAttributedString(
        string: text.replacingOccurrences(of: "\n", with: lineSeparator),
        attributes: [
            .font: PlatformFont.monospacedSystemFont(ofSize: style.font.pointSize * 0.92, weight: .regular),
            .foregroundColor: style.ink,
        ]
    )
}

private func inline(_ text: AttributedString, style: ReplyStyle, font base: PlatformFont? = nil) -> NSMutableAttributedString {
    let base = base ?? style.font
    let out = NSMutableAttributedString()
    for run in text.runs {
        let intent = run.inlinePresentationIntent ?? []
        var font = intent.contains(.code)
            ? PlatformFont.monospacedSystemFont(ofSize: base.pointSize * 0.92, weight: .regular)
            : base
        if intent.contains(.stronglyEmphasized) { font = weighted(font, bold: true) }
        if intent.contains(.emphasized) { font = italic(font) }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.ink]
        if intent.contains(.code) { attributes[.backgroundColor] = style.ink.withAlphaComponent(0.08) }
        if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = run.link { attributes[.link] = link }
        let string = String(text[run.range].characters).replacingOccurrences(of: "\n", with: lineSeparator)
        out.append(NSAttributedString(string: string, attributes: attributes))
    }
    return out
}

private func weighted(_ font: PlatformFont, bold: Bool) -> PlatformFont {
    #if os(macOS)
    NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.bold), size: font.pointSize) ?? font
    #else
    font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitBold)).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
    #endif
}

private func italic(_ font: PlatformFont) -> PlatformFont {
    #if os(macOS)
    NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic)), size: font.pointSize) ?? font
    #else
    font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
    #endif
}

private extension PlatformFont {
    var monospacedDigits: PlatformFont { PlatformFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .regular) }
}

/// The selection as the agent wrote it: a blank line between bubbles and between paragraphs, one
/// newline between list items, code lines as they were.
func replyCopy(_ text: NSAttributedString) -> String {
    let string = text.string as NSString
    var out = ""
    var previous: (bubble: Int, kind: String)?
    string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { paragraph, range, _, _ in
        let attributes = range.length > 0 ? text.attributes(at: range.location, effectiveRange: nil) : [:]
        let bubble = attributes[.replyBubble] as? Int ?? previous?.bubble ?? 0
        let kind = attributes[.replyKind] as? String ?? ReplyKind.prose.rawValue
        if let previous {
            let tight = previous.bubble == bubble && previous.kind == ReplyKind.item.rawValue && kind == ReplyKind.item.rawValue
            out += tight ? "\n" : "\n\n"
        }
        out += (paragraph ?? "").replacingOccurrences(of: lineSeparator, with: "\n").replacingOccurrences(of: "\t", with: " ")
        previous = (bubble, kind)
    }
    return out
}

// MARK: Layout

struct BubbleShape {
    var rect: CGRect
    var first: Bool
}

struct BubbleLayout {
    var bubbles: [BubbleShape] = []
    var cards: [CGRect] = []
    var bars: [CGRect] = []
    /// Where the text sits so the first bubble's padding starts at the top of the view.
    var origin = CGPoint.zero
    var size = CGSize.zero
}

/// The bubbles drawn behind the laid-out text, in the text container's coordinates moved by `origin`.
func measureBubbles(_ manager: NSTextLayoutManager) -> BubbleLayout {
    var lines: [Int: CGRect] = [:]
    var codes: [(bubble: Int, rect: CGRect)] = []
    var quotes: [CGRect] = []
    manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
        guard let paragraph = fragment.textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else { return true }
        let attributes = paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
        let bubble = attributes[.replyBubble] as? Int ?? 0
        var rect = CGRect.null
        for line in fragment.textLineFragments {
            rect = rect.union(line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY))
        }
        guard !rect.isNull else { return true }
        switch ReplyKind(rawValue: attributes[.replyKind] as? String ?? "") {
        case .code:
            let card = rect.insetBy(dx: -cardInset, dy: -cardInset)
            codes.append((bubble, card))
            lines[bubble] = (lines[bubble] ?? .null).union(card)
        case .quote:
            quotes.append(CGRect(x: rect.minX - 10, y: rect.minY, width: 3, height: rect.height))
            lines[bubble] = (lines[bubble] ?? .null).union(rect)
        default:
            lines[bubble] = (lines[bubble] ?? .null).union(rect)
        }
        return true
    }
    var layout = BubbleLayout()
    var rights: [Int: CGFloat] = [:]
    for bubble in lines.keys.sorted() {
        let content = lines[bubble]!
        let rect = CGRect(
            x: 0,
            y: content.minY - bubblePadding,
            width: content.maxX + bubbleInset,
            height: content.height + 2 * bubblePadding
        )
        rights[bubble] = rect.maxX
        layout.bubbles.append(BubbleShape(rect: rect, first: bubble == 0))
    }
    layout.cards = codes.map { code in
        CGRect(x: bubbleInset, y: code.rect.minY, width: (rights[code.bubble] ?? 0) - 2 * bubbleInset, height: code.rect.height)
    }
    layout.bars = quotes
    let top = layout.bubbles.map(\.rect.minY).min() ?? 0
    let bottom = layout.bubbles.map(\.rect.maxY).max() ?? 0
    layout.origin = CGPoint(x: 0, y: -top)
    layout.size = CGSize(width: layout.bubbles.map(\.rect.maxX).max() ?? 0, height: bottom - top)
    return layout
}

func bubblePath(_ shape: BubbleShape) -> CGPath {
    UnevenRoundedRectangle(
        topLeadingRadius: shape.first ? 20 : 6,
        bottomLeadingRadius: 6,
        bottomTrailingRadius: 20,
        topTrailingRadius: 20
    )
    .path(in: shape.rect)
    .cgPath
}

/// A layout manager holds its content storage weakly, so whoever makes the view keeps the storage.
func textKit2Stack() -> (NSTextContentStorage, NSTextContainer) {
    let container = NSTextContainer(size: CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
    let manager = NSTextLayoutManager()
    manager.textContainer = container
    let storage = NSTextContentStorage()
    storage.addTextLayoutManager(manager)
    return (storage, container)
}

struct BubbleColors {
    var fill: CGColor
    var card: CGColor
    var cardEdge: CGColor
    var bar: CGColor
}

func drawBubbles(_ layout: BubbleLayout, colors: BubbleColors, in context: CGContext) {
    context.saveGState()
    context.translateBy(x: layout.origin.x, y: layout.origin.y)
    context.setFillColor(colors.fill)
    for bubble in layout.bubbles {
        context.addPath(bubblePath(bubble))
        context.fillPath()
    }
    for card in layout.cards {
        let path = CGPath(roundedRect: card, cornerWidth: 10, cornerHeight: 10, transform: nil)
        context.setFillColor(colors.card)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(colors.cardEdge)
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 9.5, cornerHeight: 9.5, transform: nil))
        context.strokePath()
    }
    context.setFillColor(colors.bar)
    for bar in layout.bars {
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        context.fillPath()
    }
    context.restoreGState()
}

// MARK: SwiftUI

/// A run of bubbles as one native text, so a selection runs from one bubble into the next.
struct ReplyText: View {
    let chunks: [String]
    var files: FileSource?
    let fill: Color
    let link: Color
    var actions: [ReplyAction] = []

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        BubbleTextRepresentable(
            content: BubbleContent(chunks: chunks, linking: files != nil, dark: scheme == .dark, typeSize: typeSize),
            fill: fill,
            link: link,
            actions: actions
        )
    }
}

struct BubbleContent: Equatable {
    var chunks: [String]
    var linking: Bool
    var dark: Bool
    var typeSize: DynamicTypeSize

    func document() -> NSAttributedString {
        let ink = PlatformColor(Theme.ink.rgb(dark: dark).color)
        let muted = PlatformColor(Theme.muted.rgb(dark: dark).color)
        #if os(macOS)
        let font = NSFont.preferredFont(forTextStyle: .body)
        #else
        let font = UIFont.preferredFont(forTextStyle: .body)
        #endif
        return replyDocument(chunks, linkingFiles: linking, style: ReplyStyle(font: font, ink: ink, muted: muted))
    }

    func colors(fill: Color) -> BubbleColors {
        let ink = Theme.ink.rgb(dark: dark).color
        let ground = Theme.ground.rgb(dark: dark).color
        return BubbleColors(
            fill: PlatformColor(fill).cgColor,
            card: PlatformColor(ground.opacity(0.5)).cgColor,
            cardEdge: PlatformColor(ink.opacity(0.12)).cgColor,
            bar: PlatformColor(ink.opacity(0.25)).cgColor
        )
    }
}

#if os(macOS)

struct BubbleTextRepresentable: NSViewRepresentable {
    let content: BubbleContent
    let fill: Color
    let link: Color
    let actions: [ReplyAction]

    func makeNSView(context: Context) -> BubbleTextView {
        let (storage, container) = textKit2Stack()
        let view = BubbleTextView(frame: .zero, textContainer: container)
        view.storage = storage
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: BubbleTextView, context: Context) {
        context.coordinator.open = context.environment.openURL
        view.actions = actions
        view.linkTextAttributes = [.foregroundColor: PlatformColor(link), .cursor: NSCursor.pointingHand]
        view.selectedTextAttributes = [.backgroundColor: PlatformColor(link.opacity(0.28))]
        view.colors = content.colors(fill: fill)
        if view.content != content {
            view.content = content
            view.textStorage?.setAttributedString(content.document())
            view.invalidateBubbles()
        }
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: BubbleTextView, context: Context) -> CGSize? {
        view.fit(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 560)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var open: OpenURLAction?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            open?(url)
            return true
        }
    }
}

final class BubbleTextView: NSTextView {
    var content: BubbleContent?
    var storage: NSTextContentStorage?
    var colors: BubbleColors?
    var actions: [ReplyAction] = []
    private var layout = BubbleLayout()
    private var wrap: CGFloat = 0
    private var stale = true

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isRichText = true
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func invalidateBubbles() { stale = true }

    func fit(width: CGFloat) -> CGSize {
        let wrap = max(width - 48, 80)
        if stale || wrap != self.wrap, let manager = textLayoutManager {
            self.wrap = wrap
            textContainer?.size = CGSize(width: wrap, height: .greatestFiniteMagnitude)
            layout = measureBubbles(manager)
            stale = false
            invalidateTextContainerOrigin()
        }
        return CGSize(width: min(width, ceil(layout.size.width)), height: ceil(layout.size.height))
    }

    override var textContainerOrigin: NSPoint { layout.origin }

    override func drawBackground(in rect: NSRect) {
        guard let colors, let context = NSGraphicsContext.current?.cgContext else { return }
        drawBubbles(layout, colors: colors, in: context)
    }

    override func copy(_ sender: Any?) {
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard let storage = textStorage, !ranges.isEmpty else { return super.copy(sender) }
        let text = ranges.map { replyCopy(storage.attributedSubstring(from: $0)) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard !actions.isEmpty else { return menu }
        menu.addItem(.separator())
        for (index, action) in actions.enumerated() {
            let item = NSMenuItem(title: action.title, action: #selector(runAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func runAction(_ item: NSMenuItem) {
        guard actions.indices.contains(item.tag) else { return }
        actions[item.tag].perform()
    }
}

#else

struct BubbleTextRepresentable: UIViewRepresentable {
    let content: BubbleContent
    let fill: Color
    let link: Color
    let actions: [ReplyAction]

    func makeUIView(context: Context) -> BubbleTextView {
        let (storage, container) = textKit2Stack()
        let view = BubbleTextView(frame: .zero, textContainer: container)
        view.storage = storage
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: BubbleTextView, context: Context) {
        context.coordinator.open = context.environment.openURL
        context.coordinator.actions = actions
        view.linkTextAttributes = [.foregroundColor: PlatformColor(link)]
        view.colors = content.colors(fill: fill)
        if view.content != content {
            view.content = content
            view.attributedText = content.document()
            view.invalidateBubbles()
        }
        view.backdrop.setNeedsDisplay()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: BubbleTextView, context: Context) -> CGSize? {
        view.fit(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 360)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        var open: OpenURLAction?
        var actions: [ReplyAction] = []

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return UIAction { [open] _ in open?(url) }
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            let extra = actions.map { action in
                UIAction(title: action.title, image: UIImage(systemName: action.symbol)) { _ in action.perform() }
            }
            return UIMenu(children: suggestedActions + [UIMenu(options: .displayInline, children: extra)])
        }
    }
}

final class BubbleTextView: UITextView {
    var content: BubbleContent?
    var storage: NSTextContentStorage?
    var colors: BubbleColors? {
        didSet { backdrop.colors = colors }
    }
    let backdrop = Backdrop()
    private var wrap: CGFloat = 0
    private var stale = true

    final class Backdrop: UIView {
        var layout = BubbleLayout()
        var colors: BubbleColors?

        override func draw(_ rect: CGRect) {
            guard let colors, let context = UIGraphicsGetCurrentContext() else { return }
            drawBubbles(layout, colors: colors, in: context)
        }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        backdrop.backgroundColor = .clear
        backdrop.isUserInteractionEnabled = false
        insertSubview(backdrop, at: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func invalidateBubbles() { stale = true }

    func fit(width: CGFloat) -> CGSize {
        let wrap = max(width - 48, 80)
        if stale || wrap != self.wrap, let manager = textLayoutManager {
            self.wrap = wrap
            textContainer.size = CGSize(width: wrap, height: .greatestFiniteMagnitude)
            backdrop.layout = measureBubbles(manager)
            textContainerInset = UIEdgeInsets(top: backdrop.layout.origin.y, left: 0, bottom: 0, right: 0)
            stale = false
            backdrop.setNeedsDisplay()
        }
        return CGSize(width: min(width, ceil(backdrop.layout.size.width)), height: ceil(backdrop.layout.size.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = CGRect(origin: .zero, size: CGSize(width: max(bounds.width, wrap + 48), height: bounds.height))
        sendSubviewToBack(backdrop)
    }

    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else { return super.copy(sender) }
        UIPasteboard.general.string = replyCopy(attributedText.attributedSubstring(from: selectedRange))
    }
}

#endif
