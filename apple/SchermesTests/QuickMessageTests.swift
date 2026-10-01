import Testing
@testable import Schermes

private let names = ["scout", "mo-g1-2", "ledger"]

@Test func anAtNameWithDashesGoesToThatAgent() {
    #expect(quickMessage("@mo-g1-2 book the room", agents: names) == .to(agent: "mo-g1-2", text: "book the room"))
    #expect(quickMessage("  @Scout, look again ", agents: names) == .to(agent: "scout", text: "look again"))
    #expect(quickMessage("@ledger:pay it", agents: names) == .to(agent: "ledger", text: "pay it"))
}

@Test func anUnknownNameIsNotSentToAnyone() {
    #expect(quickMessage("@nobody hi", agents: names) == .unknown("nobody"))
    #expect(quickMessage("@mo hi", agents: names) == .unknown("mo"))
}

@Test func emptyTextAndPlainTextAreTellable() {
    #expect(quickMessage("", agents: names) == .empty)
    #expect(quickMessage("   \n", agents: names) == .empty)
    #expect(quickMessage("@scout", agents: names) == .to(agent: "scout", text: ""))
    #expect(quickMessage("mail bob@x.com", agents: names) == .plain("mail bob@x.com"))
    #expect(quickMessage("@ hi", agents: names) == .plain("@ hi"))
}
