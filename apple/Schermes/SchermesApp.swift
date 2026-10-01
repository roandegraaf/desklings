import Combine
import SwiftUI
import UserNotifications

/// The Mac's own About item, which lives in the app menu rather than in any window. A
/// notification rather than a flag on the scene: an `@State` on the `App` driving a sheet inside
/// the `WindowGroup` stopped the window being made at all, and the sheet belongs in `RootView`
/// anyway.
extension Notification.Name {
    static let showAbout = Notification.Name("dev.schermes.showAbout")
    /// Posted with the window whose sidebar to toggle.
    static let toggleSidebar = Notification.Name("dev.schermes.toggleSidebar")
    static let showSettings = Notification.Name("dev.schermes.showSettings")
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let relay = NotificationRelay()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = relay
        PushCategory.register()
        LiveActivityTokens.observe()
        #if DEBUG
        DebugActivity.startIfAsked()
        #endif
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
    private let shareService = ShareService()

    func applicationWillFinishLaunching(_ notification: Notification) {
        if hostingTests { NSApp.setActivationPolicy(.prohibited) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !hostingTests else { return }
        UNUserNotificationCenter.current().delegate = relay
        PushCategory.register()
        PanelHotKey.register()
        NSApp.servicesProvider = shareService
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationRelay.registered(deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        NotificationRelay.failed(error)
    }
}
#endif

/// `xcodebuild test` launches the app as the test host on the owner's Mac: it must not come to the
/// front, take a global hot key or sign in (a Keychain read can raise an authorisation panel).
#if DEBUG
let hostingTests = ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }
#else
let hostingTests = false
#endif

@main
struct SchermesApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif

    /// Lifted out of `RootView` because the Mac's desktop windows and menu bar panel are scenes of
    /// their own and need the same one.
    @State private var session = Session()
    /// Up here for the same reason: the Mac's desktop windows are a scene of their own.
    @State private var looks = AgentLooks()
    @State private var desktops = Desktops()
    #if os(macOS)
    @State private var feed = MenuBarFeed()
    #endif

    var body: some Scene {
        WindowGroup(id: consoleWindowID) {
            if !hostingTests {
                RootView(session: session)
                    .environment(looks)
                    .environment(desktops)
                    .tint(Theme.ink)
            }
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 680)
        // No New Window: it took ⌘N from New agent, and a second console could open a second
        // viewer on the desktop the first one's inspector is already showing.
        .commands {
            CommandGroup(replacing: .newItem) {}
            // The split is our own `MacSplit`; the window answers toggleSidebar: itself and finds no
            // sidebar-behaviour item in it.
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: NSApp.keyWindow)
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Schermes") {
                    NotificationCenter.default.post(name: .showAbout, object: nil)
                }
            }
            CommandGroup(replacing: .appSettings) { SettingsCommand() }
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
                    .tint(Theme.ink)
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

        #if os(macOS)
        MenuBarExtra {
            MenuBarPanel(session: session, looks: looks, feed: feed)
                .environment(looks)
                .tint(Theme.ink)
        } label: {
            MenuBarLabel(session: session, looks: looks, feed: feed)
        }
        .menuBarExtraStyle(.window)
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
        #if os(macOS)
        .containerBackground(Theme.window, for: .window)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
        .environment(unread)
        .environment(pushRegistration)
        .sheet(isPresented: $about) { AboutView() }
        .onReceive(NotificationCenter.default.publisher(for: .showAbout)) { _ in about = true }
        .task { await session.start() }
    }
}
