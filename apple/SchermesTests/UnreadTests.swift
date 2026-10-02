import Foundation
import Testing
@testable import Schermes

@Test func adoptingDaemonMarksNeverMovesAThreadBackToUnread() {
    let defaults = UserDefaults(suiteName: "UnreadTests")!
    defaults.removePersistentDomain(forName: "UnreadTests")
    let unread = Unread(defaults: defaults)
    #expect(unread.see(.agent("ada"), through: 10))
    #expect(!unread.see(.agent("ada"), through: 4))
    unread.adopt(["agent:ada": 6, "conversation:3": 8])
    #expect(unread.lastSeen(.agent("ada")) == 10)
    #expect(!unread.has(.conversation(3), newest: 8))
    #expect(Unread(defaults: defaults).lastSeen(.conversation(3)) == 8)
}
