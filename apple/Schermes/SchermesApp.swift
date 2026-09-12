import Combine
import SwiftUI

/// The Mac's own About item, which lives in the app menu rather than in any window. A
/// notification rather than a flag on the scene: an `@State` on the `App` driving a sheet inside
/// the `WindowGroup` stopped the window being made at all, and the sheet belongs in `RootView`
/// anyway — that is where the session it shows lives.
extension Notification.Name {
    static let showAbout = Notification.Name("dev.schermes.showAbout")
}

@main
struct SchermesApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 680)
        // No New Window: it took ⌘N from New agent, and a second console could open a second
        // viewer on the desktop the first one's inspector is already showing.
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Schermes") {
                    NotificationCenter.default.post(name: .showAbout, object: nil)
                }
            }
        }
        #endif
    }
}

struct RootView: View {
    @State private var session = Session()
    // Outlives the session: an agent keeps its look across a log out.
    @State private var looks = AgentLooks()
    @State private var unread = Unread()
    @State private var about = false

    var body: some View {
        Group {
            switch session.phase {
            case .connecting:
                ProgressView()
            case .needsServer:
                ConnectView(session: session)
            case .setup, .login:
                GateView(session: session)
            case .ready:
                ConsoleView(session: session)
            }
        }
        .environment(looks)
        .environment(unread)
        .sheet(isPresented: $about) { AboutView(session: session) }
        .onReceive(NotificationCenter.default.publisher(for: .showAbout)) { _ in about = true }
        .task { await session.start() }
    }
}
