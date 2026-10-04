import SwiftUI

/// One colour with its light and dark value, usable anywhere a `ShapeStyle` is.
struct Token: ShapeStyle {
    let light: BloubRGB
    let dark: BloubRGB

    init(_ light: UInt32, _ dark: UInt32) {
        self.light = BloubRGB(hex: light)
        self.dark = BloubRGB(hex: dark)
    }

    func rgb(dark isDark: Bool) -> BloubRGB { isDark ? dark : light }

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        let c = rgb(dark: environment.colorScheme == .dark)
        return Color.Resolved(colorSpace: .sRGB, red: Float(c.r), green: Float(c.g), blue: Float(c.b))
    }
}

/// The canvas's Foundations page. Warm paper instead of grey; the only other colour is the agents'.
enum Theme {
    static let ground = Token(0xf6f4ef, 0x17161a)
    static let window = Token(0xefebe3, 0x0f0e12)
    static let ink = Token(0x16150f, 0xf3f1ec)
    static let secondary = Token(0x4a463e, 0xcfcbd6)
    static let muted = Token(0x6b675e, 0xa8a4b3)
    static var hairline: some ShapeStyle { ink.opacity(0.08) }

    static let needsYou = Token(0x9a4d00, 0xf5a55a)
    static let failed = Token(0xb3261e, 0xff8a80)
    static let retrying = Token(0x8b6818, 0xe8c35a)
    static let done = Token(0x17754d, 0x5fd39a)
    /// Needs you's own ground: the iPhone strip.
    static let needsYouFill = Token(0xfbd9b4, 0x4a2c10)
    /// The quieter Needs you ground: the Mac sidebar row and the menu bar rows.
    static let needsYouSoft = Token(0xfdeedd, 0x33261b)
    /// The Mac sidebar's Needs you icon tile, with dark ink on it in both modes.
    static let needsYouTile = Token(0xf08a24, 0xf08a24)
    static let onNeedsYouTile = Token(0x16150f, 0x16150f)
    /// A card on the ground.
    static let card = Token(0xffffff, 0x232127)
    /// The Mac sidebar and inspector. Solid: the canvas's white 66% has nothing behind it to show.
    static let panel = Token(0xfbfaf7, 0x1c1b20)
    /// Text on an ink or failed fill.
    static let onInk = Token(0xffffff, 0x16150f)
    /// The dark bezel around an agent's screen thumbnail.
    static let screenFrame = Token(0x2a2640, 0x2a2640)
}

extension Font {
    /// The canvas's point size on the Mac, where text styles run small; the nearest Dynamic Type
    /// style on iOS.
    static func canvas(
        _ size: CGFloat, _ style: Font.TextStyle, weight: Font.Weight = .regular, design: Font.Design = .default
    ) -> Font {
        #if os(macOS)
        .system(size: size, weight: weight, design: design)
        #else
        .system(style, design: design, weight: weight)
        #endif
    }

    #if os(macOS)
    static let sectionTitle = Font.system(size: 16, weight: .bold, design: .rounded)
    static let pageTitle = Font.system(size: 34, weight: .bold, design: .rounded)
    #else
    static let sectionTitle = Font.system(.headline, design: .rounded, weight: .bold)
    static let pageTitle = Font.system(.title, design: .rounded, weight: .bold)
    #endif
}

/// An agent's colours for its thread, from the canvas's Colour check, which is the spec: the maths
/// below is a literal port of its script, rounding and step accumulation included, so the hexes
/// match the canvas's to the digit.
struct AgentPalette: Equatable {
    /// The ground with a breath of the agent's colour: its thread and its cards.
    let tint: BloubRGB
    /// The owner's bubble, and any filled control in the agent's colour.
    let bubble: BloubRGB
    let bubbleText: BloubRGB
    /// The agent's colour as text or an icon on its tint.
    let accentText: BloubRGB
    /// A selected row, an icon tile, a soft button: the agent's colour lightly on white.
    let soft: BloubRGB
    /// The agent's colour as text on `soft`, a step darker (or lighter) than `accentText`.
    let softText: BloubRGB

    init(_ color: BloubColorId, dark: Bool) {
        let base = Self.channels(color.rgb)
        let ground = Self.channels(Theme.ground.rgb(dark: dark))
        let ink = Self.channels(Theme.ink.rgb(dark: dark))
        let white = SIMD3<Double>(255, 255, 255)
        let black = SIMD3<Double>(0, 0, 0)
        let darkText = Self.channels(BloubRGB(hex: 0x16150f))

        let tint = Self.mix(ground, base, 7.0 / 100 * (dark ? 1.7 : 1))
        let whiteText = Self.toward(base, black, on: white)
        var bubble = whiteText.t <= 0.26 ? whiteText.color : base
        var bubbleText = whiteText.t <= 0.26 ? white : darkText
        // Cream on a light thread and ink on a dark one: a bubble that vanishes into its ground.
        if Self.contrast(bubble, tint) < 1.25 {
            bubble = ink
            bubbleText = dark ? darkText : white
        }
        let accent = Self.toward(base, dark ? white : black, on: tint)

        self.tint = Self.rgb(tint)
        self.bubble = Self.rgb(bubble)
        self.bubbleText = Self.rgb(bubbleText)
        self.accentText = Self.rgb(accent.color)
        let soft = Self.mix(Self.channels(BloubRGB(hex: dark ? 0x26242b : 0xffffff)), base, dark ? 0.22 : 0.16)
        self.soft = Self.rgb(soft)
        self.softText = Self.rgb(Self.toward(base, dark ? white : black, on: soft).color)
    }

    static func contrast(_ a: BloubRGB, _ b: BloubRGB) -> Double {
        contrast(channels(a), channels(b))
    }

    // Whole 0–255 channels, as the canvas mixes through hex strings.
    private static func channels(_ rgb: BloubRGB) -> SIMD3<Double> {
        (SIMD3(rgb.r, rgb.g, rgb.b) * 255).rounded(.toNearestOrAwayFromZero)
    }

    private static func rgb(_ c: SIMD3<Double>) -> BloubRGB {
        BloubRGB(r: c.x / 255, g: c.y / 255, b: c.z / 255)
    }

    private static func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        (a + (b - a) * t).rounded(.toNearestOrAwayFromZero)
    }

    private static func luminance(_ c: SIMD3<Double>) -> Double {
        let linear = { (v: Double) -> Double in
            let v = v / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.x) + 0.7152 * linear(c.y) + 0.0722 * linear(c.z)
    }

    private static func contrast(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Steps the colour toward `to` until it reads at 4.5:1 on `background`. Accumulated rather than
    /// `i * 0.02`: the canvas adds, and pink's bubble lands on an exact half only one way.
    private static func toward(
        _ color: SIMD3<Double>, _ to: SIMD3<Double>, on background: SIMD3<Double>
    ) -> (color: SIMD3<Double>, t: Double) {
        var t = 0.0
        while t <= 1.0001 {
            let mixed = mix(color, to, t)
            if contrast(mixed, background) >= 4.5 { return (mixed, t) }
            t += 0.02
        }
        return (to, 1)
    }
}

extension BloubIdentity {
    func palette(dark: Bool) -> AgentPalette { AgentPalette(color, dark: dark) }
}

enum StateRole {
    /// Mid-turn: the word takes the agent's own accent.
    case busy
    case quiet
    case done
    case failed
}

extension AgentState {
    /// Never colour alone: every state is a symbol and a word, and the colour only repeats them.
    var presentation: (symbol: String, word: String, role: StateRole) {
        switch self {
        case .idle: ("moon.zzz", "Idle", .quiet)
        case .thinking: ("ellipsis.bubble", "Thinking", .busy)
        case .using_computer: ("cursorarrow.rays", "Using the computer", .busy)
        case .using_terminal: ("terminal", "Using the terminal", .busy)
        case .waiting_for_user: ("bubble.left", "Ready", .quiet)
        case .waiting_for_agent: ("hourglass", "Waiting for an agent", .quiet)
        case .waiting_for_task_worker: ("hourglass", "Waiting for a task worker", .quiet)
        case .failed: ("exclamationmark.triangle", "Failed", .failed)
        case .completed: ("checkmark.circle", "Done", .done)
        case .unknown: ("questionmark.circle", "Unknown state", .quiet)
        }
    }
}

struct StateLine: View {
    let state: AgentState
    let identity: BloubIdentity
    var font: Font = .caption.weight(.semibold)

    @Environment(\.colorScheme) private var scheme

    private var style: AnyShapeStyle {
        switch state.presentation.role {
        case .busy: AnyShapeStyle(identity.palette(dark: scheme == .dark).accentText.color)
        case .quiet: AnyShapeStyle(Theme.muted)
        case .done: AnyShapeStyle(Theme.done)
        case .failed: AnyShapeStyle(Theme.failed)
        }
    }

    var body: some View {
        let presentation = state.presentation
        // Not a `Label`: a list row sets its icon in a column of its own, away from the word.
        HStack(spacing: 4) {
            Image(systemName: presentation.symbol)
            Text(presentation.word)
        }
        .font(font)
        .foregroundStyle(style)
        .lineLimit(1)
    }
}

extension View {
    /// The canvas's busy mark: a ring of the agent's own colour just outside its bloub.
    func busyHalo(_ busy: Bool, color: BloubColorId) -> some View {
        overlay {
            if busy {
                Circle().strokeBorder(color.rgb.color.opacity(0.45), lineWidth: 2).padding(-3)
            }
        }
    }
}

/// How full an agent's thread is, as the daemon reports it against the point it compacts.
enum ContextFullness {
    static func clamped(_ percent: Int) -> Int { min(max(percent, 0), 100) }
    static func label(_ percent: Int) -> String { "Context \(clamped(percent))% full" }
}

/// The fullness as a ring in the agent's bubble colour, starting at the top.
struct ContextRing: View {
    let percent: Int
    let identity: BloubIdentity
    var radius: CGFloat = 7
    var lineWidth: CGFloat = 3

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Circle().stroke(Theme.ink.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: Double(ContextFullness.clamped(percent)) / 100)
                .stroke(
                    identity.palette(dark: scheme == .dark).bubble.color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: radius * 2, height: radius * 2)
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

/// The Mac chat header's meter: the ring and the percentage.
struct ContextMeter: View {
    let percent: Int
    let identity: BloubIdentity

    var body: some View {
        HStack(spacing: 6) {
            ContextRing(percent: percent, identity: identity, radius: 8.5)
            Text("\(ContextFullness.clamped(percent))%")
                .font(.canvas(12, .caption, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ContextFullness.label(percent))
    }
}

/// The canvas's six buttons. Height follows `controlSize`: small 30, regular 36 (40 on iPhone), large 44.
struct PillButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        /// Filled in the agent's bubble colour; ink when there is no one agent.
        case agent(BloubColorId?)
        case secondary
        case outline(BloubColorId?)
        case soft(BloubColorId?)
        case destructive
    }

    let kind: Kind
    /// A circle the height of the pill, for an icon-only label.
    var round = false

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, kind: kind, round: round)
    }

    private struct Pill: View {
        let configuration: Configuration
        let kind: Kind
        let round: Bool

        @Environment(\.colorScheme) private var scheme
        @Environment(\.controlSize) private var controlSize
        @Environment(\.isEnabled) private var isEnabled
        @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1

        private var metrics: (height: CGFloat, padding: CGFloat, font: Font) {
            let (height, padding, size): (CGFloat, CGFloat, CGFloat) = switch controlSize {
            case .mini, .small: (30, 12, 13)
            case .large, .extraLarge: (44, 17, 14)
            default:
                #if os(iOS)
                (40, 15, 14)
                #else
                (36, 14, 13)
                #endif
            }
            return (height * scale, padding, .system(size: (round ? size + 3 : size) * scale, weight: .semibold))
        }

        private func palette(_ color: BloubColorId) -> AgentPalette { AgentPalette(color, dark: scheme == .dark) }

        private var colors: (fill: AnyShapeStyle, text: AnyShapeStyle, border: AnyShapeStyle?) {
            switch kind {
            case .primary, .agent(nil):
                (AnyShapeStyle(Theme.ink), AnyShapeStyle(Theme.onInk), nil)
            case .agent(let color?):
                (AnyShapeStyle(palette(color).bubble.color), AnyShapeStyle(palette(color).bubbleText.color), nil)
            case .secondary, .soft(nil):
                (AnyShapeStyle(Theme.ink.opacity(0.06)), AnyShapeStyle(Theme.ink), nil)
            case .outline(nil):
                (AnyShapeStyle(Theme.card), AnyShapeStyle(Theme.ink), AnyShapeStyle(Theme.ink.opacity(0.2)))
            case .outline(let color?):
                (
                    AnyShapeStyle(Theme.card), AnyShapeStyle(palette(color).softText.color),
                    AnyShapeStyle(palette(color).bubble.color.opacity(0.45))
                )
            case .soft(let color?):
                (AnyShapeStyle(palette(color).soft.color), AnyShapeStyle(palette(color).softText.color), nil)
            case .destructive:
                (AnyShapeStyle(Theme.failed), AnyShapeStyle(Theme.onInk), nil)
            }
        }

        var body: some View {
            let metrics = metrics
            let colors = colors
            configuration.label
                .font(metrics.font)
                .foregroundStyle(colors.text)
                .padding(.horizontal, round ? 0 : metrics.padding)
                .frame(minWidth: round ? metrics.height : nil, minHeight: metrics.height)
                .background(colors.fill, in: .capsule)
                .overlay {
                    if let border = colors.border { Capsule().strokeBorder(border, lineWidth: 1) }
                }
                .contentShape(.capsule)
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static func pill(_ kind: PillButtonStyle.Kind, round: Bool = false) -> PillButtonStyle {
        PillButtonStyle(kind: kind, round: round)
    }
}

/// A `Form` on the warm ground with card sections, instead of the stock grouped grey. On iOS the
/// rows take their colour through the `Group`: `listRowBackground` on the `Form` itself is ignored.
/// The Mac's grouped style draws its section box with no way to recolour it, so the Mac lays the
/// sections out itself.
struct ThemedForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if os(macOS)
        Form { content }
            .formStyle(CardFormStyle())
            .labeledContentStyle(CardRowLabeled())
            .toggleStyle(CardRowToggle())
            .background(Theme.ground)
        #else
        Form {
            Group { content }.listRowBackground(Rectangle().fill(Theme.card))
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        #endif
    }
}

#if os(macOS)
/// MacSettings' cards: white r18 with the ink 8% border, a hairline between rows.
private struct CardFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(sections: configuration.content) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        if !section.header.isEmpty {
                            section.header
                                .padding(.horizontal, 4)
                                .accessibilityAddTraits(.isHeader)
                        }
                        if !section.content.isEmpty { card(section.content) }
                        if !section.footer.isEmpty {
                            section.footer
                                .font(.footnote)
                                .foregroundStyle(Theme.muted)
                                .padding(.horizontal, 4)
                        }
                    }
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(20)
            // A sheet sizes to its content's ideal width, which a bare scroll view keeps narrow.
            .frame(idealWidth: 520, maxWidth: .infinity, alignment: .leading)
        }
    }

    private func card(_ rows: SubviewsCollection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(subviews: rows) { row in
                if row.id != rows.first?.id {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                row
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .background(Theme.card, in: .rect(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline) }
    }
}

/// The grouped form's row: label left, control right. The label's minimum width lines text fields
/// up across rows, as the native grouped form did.
private struct CardRowLabeled: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: LabeledContentStyleConfiguration
        @Environment(\.labelsVisibility) private var labels

        var body: some View {
            if labels == .hidden {
                configuration.content
            } else {
                HStack(spacing: 12) {
                    configuration.label.frame(minWidth: 110, alignment: .leading)
                    Spacer(minLength: 0)
                    configuration.content
                }
            }
        }
    }
}

private struct CardRowToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.labelsVisibility) private var labels

        var body: some View {
            let control = Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
                .labelsHidden()
            if labels == .hidden {
                control
            } else {
                HStack(spacing: 12) {
                    configuration.label
                    Spacer(minLength: 0)
                    control
                }
            }
        }
    }
}
#endif

/// A picker as MacSettings draws it: the label, then the bold value with a chevron that opens the
/// options. Honours `labelsHidden()` for rows that draw their own title. iOS keeps the stock menu.
struct ValueMenu<Value: Hashable, Options: View>: View {
    let title: String
    let value: String
    @Binding var selection: Value
    @ViewBuilder let options: Options

    init(_ title: String, value: String, selection: Binding<Value>, @ViewBuilder options: () -> Options) {
        self.title = title
        self.value = value
        _selection = selection
        self.options = options()
    }

    #if os(macOS)
    @Environment(\.labelsVisibility) private var labels

    var body: some View {
        if labels == .hidden {
            menu
        } else {
            LabeledContent(title) { menu }
        }
    }

    private var menu: some View {
        Menu {
            Picker(title, selection: $selection) { options }.pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(value).fontWeight(.semibold).foregroundStyle(Theme.ink)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.muted)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
    #else
    var body: some View {
        Picker(title, selection: $selection) { options }.pickerStyle(.menu)
    }
    #endif
}

extension View {
    /// A text field's label beside it on the Mac's card rows, as the grouped form drew it. iOS
    /// keeps the stock row, which shows the prompt instead.
    func formLabel(_ label: String) -> some View {
        #if os(macOS)
        LabeledContent { labelsHidden() } label: { Text(label) }
        #else
        self
        #endif
    }

    /// A sheet's chrome. The Mac draws the settings sheet's header on the ground (title left,
    /// pills right, Esc cancels); iOS keeps its navigation bar.
    func sheetChrome(
        _ title: String,
        confirm: String = "Done",
        confirmDisabled: Bool = false,
        cancel: (() -> Void)? = nil,
        onConfirm: @escaping () -> Void
    ) -> some View {
        #if os(macOS)
        VStack(spacing: 0) {
            SheetHeader(title) {
                if let cancel {
                    Button("Cancel", action: cancel)
                        .buttonStyle(.pill(.secondary))
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                }
                Button(confirm, action: onConfirm)
                    .buttonStyle(.pill(.primary))
                    .controlSize(.small)
                    .keyboardShortcut(cancel == nil ? .cancelAction : .defaultAction)
                    .disabled(confirmDisabled)
            }
            frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.ground)
        #else
        NavigationStack {
            navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let cancel {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", action: cancel)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirm, role: .confirm, action: onConfirm)
                            .disabled(confirmDisabled)
                    }
                }
        }
        #endif
    }
}

#if os(macOS)
/// The Mac sheets' header row: optional leading control, title, then the actions.
struct SheetHeader<Leading: View, Actions: View>: View {
    let title: String
    @ViewBuilder let leading: Leading
    @ViewBuilder let actions: Actions

    init(_ title: String, @ViewBuilder leading: () -> Leading, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.leading = leading()
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 10) {
            leading
            Text(title)
                .font(.sectionTitle)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            HStack(spacing: 8) { actions }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

extension SheetHeader where Leading == EmptyView {
    init(_ title: String, @ViewBuilder actions: () -> Actions) {
        self.init(title, leading: { EmptyView() }, actions: actions)
    }
}
#endif

extension Text {
    /// A form section's header: the canvas's rounded title on the Mac, its small caps label on iOS.
    func formHeader() -> some View {
        #if os(macOS)
        font(.sectionTitle).foregroundStyle(Theme.ink)
        #else
        font(.caption.weight(.bold)).kerning(0.5).textCase(.uppercase).foregroundStyle(Theme.muted)
        #endif
    }
}
