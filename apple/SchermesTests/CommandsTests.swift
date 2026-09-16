import Testing
@testable import Schermes

private func agent(_ name: String, parentId: Int? = nil) -> Agent {
    Agent(id: 1, name: name, display: 1, state: .idle, parentId: parentId, createdAt: 0)
}

private let own = ChatThread.agent(agent("alpha"))
private let group = ChatThread.group(id: 7, members: [agent("alpha"), agent("bravo")])
private let worker = ChatThread.agent(agent("alpha-w1", parentId: 1))

@Test func aSlashListsEveryCommandAndLettersNarrowIt() {
    #expect(commandMatches("/", in: own) == SlashCommand.allCases)
    #expect(commandMatches("/re", in: own) == [.retry, .remember])
    #expect(commandMatches("/Co", in: own) == [.compact])
    #expect(commandMatches("/nope", in: own).isEmpty)
}

@Test func theListClosesOnceTheOwnerIsPastTheCommand() {
    #expect(commandMatches("/remember ", in: own).isEmpty)
    #expect(commandMatches("/new\n", in: own).isEmpty)
    #expect(commandMatches("hello", in: own).isEmpty)
    #expect(commandMatches("", in: own).isEmpty)
}

@Test func aSharedThreadOffersOnlyWhatHasNoSingleAgentBehindIt() {
    #expect(commandMatches("/", in: group) == [.new, .compact, .stop, .retry, .undo])
    #expect(commandMatches("/", in: worker).isEmpty)
}

@Test func onlyAWholeNameIsACommand() {
    #expect(parseCommand("/remember use pnpm, not npm", in: own)?.command == .remember)
    #expect(parseCommand("/remember use pnpm, not npm", in: own)?.argument == "use pnpm, not npm")
    #expect(parseCommand("/New", in: own)?.command == .new)
    #expect(parseCommand("/new", in: own)?.argument == "")
    #expect(parseCommand("/home/agent-alpha/workspace/report.md", in: own) == nil)
    #expect(parseCommand("/newest", in: own) == nil)
    #expect(parseCommand("/screen", in: group) == nil)
    #expect(parseCommand("look at /new", in: own) == nil)
}

@Test func compactionIsReportedInWords() {
    let titles = ["alpha": "Alpha", "bravo": "Bob"]
    #expect(compactionNotice(CompactResult(compacted: ["alpha": 42]), titles: titles) == "Folded 42 messages into a summary.")
    #expect(compactionNotice(CompactResult(compacted: ["alpha": 1]), titles: titles) == "Folded 1 message into a summary.")
    #expect(compactionNotice(CompactResult(compacted: ["alpha": 0]), titles: titles) == "Nothing new to fold in since the last summary.")
    #expect(compactionNotice(CompactResult(compacted: ["bravo": 3, "alpha": 5]), titles: titles) == "Folded into a summary for Alpha (5), Bob (3).")
    #expect(compactionNotice(CompactResult(compacted: ["bravo": 0, "alpha": 5]), titles: titles) == "Folded into a summary for Alpha (5).")
}

@Test func aNoteLandsAsOneListItemAtTheEnd() {
    #expect(withNote("", "use pnpm") == "- use pnpm\n")
    #expect(withNote("# Memory\n- one\n\n", "two\nlines") == "# Memory\n- one\n- two lines\n")
}
