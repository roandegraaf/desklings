import Combine
import SwiftUI
import UserNotifications

/// The Mac's own About item, which lives in the app menu rather than in any window. A
/// notification rather than a flag on the scene: an `@State` on the `App` driving a sheet inside
/// the `WindowGroup` stopped the window being made at all, and the sheet belongs in `RootView`
/// anyway.
extension Notification.Name {
    static let showAbout = Notification.Name("dev.schermes.showAbout")
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let relay = NotificationRelay()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = relay
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationRelay.registered(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        NotificationRelay.failed(error)
    }
}
#else
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let relay = NotificationRelay()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = relay
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationRelay.registered(deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        NotificationRelay.failed(error)
    }
}
#endif

@main
struct SchermesApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif

    /// Lifted out of `RootView` because the Mac's `Settings` scene is a second scene and needs the
    /// same one. `pushRegistration` is already a singleton, so only this had to move.
    @State private var session = Session()
    /// Up here for the same reason: the Mac's desktop windows are a scene of their own.
    @State private var looks = AgentLooks()
    @State private var desktops = Desktops()

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .environment(looks)
                .environment(desktops)
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

        #if os(macOS)
        // Keyed by agent name, so opening a desktop that already has a window brings that window
        // forward instead of a second viewer on the same screen.
        WindowGroup("Desktop", id: desktopWindowID, for: String.self) { $name in
            if let name {
                DesktopWindow(session: session, name: name)
                    .environment(looks)
                    .environment(desktops)
            }
        }
        // As large a 16:10 picture as the display takes, the shape of the default 1920x1200 desktop.
        .defaultWindowPlacement { _, context in
            let room = context.defaultDisplay.visibleRect.size
            let toolbar: CGFloat = 52
            let width = min(room.width * 0.9, (room.height * 0.9 - toolbar) * 1.6)
            return WindowPlacement(size: CGSize(width: width, height: width / 1.6 + toolbar))
        }
        // A remote screen reopened at launch would come up before the console has signed in.
        .restorationBehavior(.disabled)
        #endif

        // Gives the app ⌘, and the app menu's Settings… item; the sidebar's gear opens it with a
        // `SettingsLink`.
        #if os(macOS)
        Settings {
            SettingsWindow(session: session)
                .environment(pushRegistration)
        }
        #endif
    }
}

let desktopWindowID = "desktop"

struct RootView: View {
    let session: Session

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
        .environment(unread)
        .environment(pushRegistration)
        .sheet(isPresented: $about) { AboutView() }
        .onReceive(NotificationCenter.default.publisher(for: .showAbout)) { _ in about = true }
        .task { await session.start() }
    }
}
