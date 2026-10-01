import Testing
@testable import Schermes
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@Test(arguments: BloubColorId.allCases, [false, true])
func paletteTextReadsAtAA(color: BloubColorId, dark: Bool) {
    let palette = AgentPalette(color, dark: dark)
    #expect(AgentPalette.contrast(palette.bubbleText, palette.bubble) >= 4.5)
    #expect(AgentPalette.contrast(palette.accentText, palette.tint) >= 4.5)
}

@Test func paletteFallsBackToTheInkBubble() {
    let cream = AgentPalette(.cream, dark: false)
    #expect(cream.bubble == Theme.ink.light)
    #expect(cream.bubbleText.hex == "#ffffff")

    let ink = AgentPalette(.ink, dark: true)
    #expect(ink.bubble == Theme.ink.dark)
    #expect(ink.bubbleText.hex == "#16150f")
}

/// Values read off the canvas (Foundations cast, PhoneHome rows), so the port stays exact.
@Test func paletteMatchesTheCanvas() {
    let bubbles: [BloubColorId: String] = [
        .violet: "#8558ec", .blue: "#2f76c0", .pink: "#c24797", .amber: "#f0b429", .teal: "#2fbfa0",
    ]
    for (color, hex) in bubbles {
        #expect(AgentPalette(color, dark: false).bubble.hex == hex, "\(color)")
    }
    #expect(AgentPalette(.amber, dark: false).bubbleText.hex == "#16150f")

    let tints: [BloubColorId: String] = [
        .violet: "#efe9ef", .amber: "#f6f0e1", .teal: "#e8f0e9", .blue: "#e9edef", .pink: "#f5e9eb",
    ]
    for (color, hex) in tints {
        #expect(AgentPalette(color, dark: false).tint.hex == hex, "\(color)")
    }
}

@Test(arguments: [false, true])
func stateTokensReadOnTheGround(dark: Bool) {
    let ground = Theme.ground.rgb(dark: dark)
    for token in [Theme.ink, Theme.secondary, Theme.muted, Theme.needsYou, Theme.failed, Theme.retrying, Theme.done] {
        #expect(AgentPalette.contrast(token.rgb(dark: dark), ground) >= 4.5, "\(token.rgb(dark: dark).hex)")
    }
}

@Test(arguments: AgentState.allCases)
func everyStateHasASymbolAndAWord(state: AgentState) {
    let presentation = state.presentation
    #expect(!presentation.word.isEmpty)
    #if canImport(AppKit)
    #expect(NSImage(systemSymbolName: presentation.symbol, accessibilityDescription: nil) != nil)
    #else
    #expect(UIImage(systemName: presentation.symbol) != nil)
    #endif
    switch state {
    case .thinking, .using_computer, .using_terminal: #expect(presentation.role == .busy)
    case .failed: #expect(presentation.role == .failed)
    case .completed: #expect(presentation.role == .done)
    case .idle, .waiting_for_user, .waiting_for_agent, .waiting_for_task_worker: #expect(presentation.role == .quiet)
    }
}

@Test func taglineIsTheProfilesFirstLineOfProse() throws {
    let agent = try JSONDecoder().decode(Agent.self, from: Data("""
    {"id":1,"name":"mo","profile":"# Mo\\n\\nBooks **travel** and errands.\\nMore.","display":1,"state":"idle","createdAt":0}
    """.utf8))
    #expect(agent.tagline == "Books travel and errands.")
}

@Test(arguments: [(-5, 0), (0, 0), (62, 62), (100, 100), (140, 100)])
func contextFullnessClampsToAPercentage(raw: Int, shown: Int) {
    #expect(ContextFullness.clamped(raw) == shown)
    #expect(ContextFullness.label(raw) == "Context \(shown)% full")
}

@Test func contextFullnessDecodesFromTheListAndIsAbsentElsewhere() throws {
    let listed = try JSONDecoder().decode(Agent.self, from: Data("""
    {"id":1,"name":"mo","display":1,"state":"idle","createdAt":0,"contextFullness":62}
    """.utf8))
    #expect(listed.contextFullness == 62)
    let single = try JSONDecoder().decode(Agent.self, from: Data("""
    {"id":1,"name":"mo","display":1,"state":"idle","createdAt":0}
    """.utf8))
    #expect(single.contextFullness == nil)
}

@Test(arguments: [false, true])
func textReadsOnThePanelAndTheNeedsYouFills(dark: Bool) {
    let panel = Theme.panel.rgb(dark: dark)
    for token in [Theme.ink, Theme.secondary, Theme.muted] {
        #expect(AgentPalette.contrast(token.rgb(dark: dark), panel) >= 4.5, "\(token.rgb(dark: dark).hex)")
    }
    for fill in [Theme.needsYouSoft, Theme.needsYouFill] {
        #expect(AgentPalette.contrast(Theme.needsYou.rgb(dark: dark), fill.rgb(dark: dark)) >= 4.5)
        #expect(AgentPalette.contrast(Theme.ink.rgb(dark: dark), fill.rgb(dark: dark)) >= 4.5)
    }
}

@Test(arguments: BloubColorId.allCases, [false, true])
func softFillTextReadsAtAA(color: BloubColorId, dark: Bool) {
    let palette = AgentPalette(color, dark: dark)
    #expect(AgentPalette.contrast(palette.softText, palette.soft) >= 4.5)
    #expect(AgentPalette.contrast(palette.softText, Theme.card.rgb(dark: dark)) >= 4.5)
}

/// The Colours script's rule, white (or the dark card) with 16% (22%) of the agent's colour.
@Test func softFillFollowsTheCanvasScript() {
    #expect(AgentPalette(.violet, dark: false).soft.hex == "#ece5fe")
    #expect(AgentPalette(.violet, dark: true).soft.hex == "#3c3058")
}

@Test(arguments: [false, true])
func pillTextReadsOnItsFill(dark: Bool) {
    #expect(AgentPalette.contrast(Theme.onInk.rgb(dark: dark), Theme.ink.rgb(dark: dark)) >= 4.5)
    #expect(AgentPalette.contrast(Theme.onInk.rgb(dark: dark), Theme.failed.rgb(dark: dark)) >= 4.5)
}
