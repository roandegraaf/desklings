import Foundation
import UserNotifications
#if os(iOS)
import ActivityKit
import UIKit
#else
import AppKit
#endif

/// The system notification centre, asked once and then handed what an agent did while the owner
/// was looking elsewhere. Local posts are the Mac's story; a phone is reached by the daemon over
/// APNs, which is why granting permission is followed by asking for a device token.
enum Notifier {
    private static var asked = false

    static func ask() {
        guard !asked, !hostingTests else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                guard granted else {
                    pushRegistration.failure = "notifications are off for Schermes in the system settings"
                    return
                }
                #if os(iOS)
                UIApplication.shared.registerForRemoteNotifications()
                #else
                NSApplication.shared.registerForRemoteNotifications()
                #endif
            }
        }
    }

    static func post(id: String, title: String, body: String, category: String? = nil, info: [String: String] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = info
        if let category { content.categoryIdentifier = category }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func badge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count)
    }
}

/// The buttons on a notification about a Needs you item. The ids are the daemon's
/// `PushCategory` and each button's id is the `NeedsYouAction` it sends, so a push and a local
/// post of the same item look and answer alike. The words mirror `Approval.yesWord`/`noWord`.
enum PushCategory {
    static let approval = "needs.approval"
    static let delete = "needs.delete"
    static let yours = "needs.yours"
    static let watch = "needs.watch"
    static let open = "needs.open"

    static func id(for item: NeedsYouItem) -> String {
        guard let approval = item.approval else { return item.kind == .handOver ? watch : open }
        if approval.kind != .action { return delete }
        return approval.category == "passwords_security" ? yours : Self.approval
    }

    /// Approving spends money or deletes, so it wants the owner unlocked; saying no never does.
    static let all: Set<UNNotificationCategory> = [
        category(approval, [
            button("approve", "Approve", [.authenticationRequired]),
            button("deny", "Don't"),
        ]),
        category(delete, [
            button("deny", "Keep it"),
            button("approve", "Delete it", [.destructive, .authenticationRequired]),
        ]),
        category(yours, [
            button("approve", "I'll do it"),
            button("deny", "Don't"),
        ]),
        category(watch, [button("open", "Watch", [.foreground])]),
        category(open, [button("open", "Open", [.foreground])]),
    ]

    /// The action a button sends to the daemon; `open` and a tap on the notification itself open
    /// the app instead.
    static func answer(_ identifier: String) -> NeedsYouAction? {
        switch identifier {
        case "approve": .approve
        case "deny": .deny
        default: nil
        }
    }

    static func register() {
        UNUserNotificationCenter.current().setNotificationCategories(all)
    }

    private static func category(_ id: String, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
        UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [])
    }

    private static func button(
        _ id: String, _ title: String, _ options: UNNotificationActionOptions = []
    ) -> UNNotificationAction {
        UNNotificationAction(identifier: id, title: title, options: options)
    }
}

/// What APNs gave this device, if anything. A simulator and an ad-hoc build get `failure`
/// instead of a token, and the daemon then has nobody to push to on this device.
@Observable
final class PushRegistration {
    var token: String?
    var failure: String?

    #if os(iOS)
    let platform = "ios"
    #else
    let platform = "macos"
    #endif

    /// What APNs will want to hear about this build, read off its own signature rather than
    /// typed: the bundle id, the team, and whether the profile says development or production.
    let bundleId = Bundle.main.bundleIdentifier ?? ""
    let teamId: String?
    let environment: String

    init() {
        let entitlements = Self.profileEntitlements()
        teamId = entitlements?["com.apple.developer.team-identifier"] as? String
        environment = entitlements?["aps-environment"] as? String ?? "production"
    }

    /// The entitlements inside the embedded provisioning profile: a CMS blob wrapping a plist. An
    /// App Store install has no profile, which is the one case that is always production.
    private static func profileEntitlements() -> [String: Any]? {
        #if os(iOS)
        let url = Bundle.main.bundleURL.appending(path: "embedded.mobileprovision")
        #else
        let url = Bundle.main.bundleURL.appending(path: "Contents/embedded.provisionprofile")
        #endif
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil)
        else { return nil }
        return (plist as? [String: Any])?["Entitlements"] as? [String: Any]
    }
}

/// Shared between the app delegate, which hears from APNs, and the views, which tell the daemon.
let pushRegistration = PushRegistration()

extension Notification.Name {
    /// A tapped push names the agent it was about; the console picks that agent's thread.
    static let openAgent = Notification.Name("dev.schermes.openAgent")
}

/// What both platforms' delegates share: the token as APNs' lowercase hex, and the two
/// notification-centre answers.
final class NotificationRelay: NSObject, UNUserNotificationCenterDelegate {
    static func registered(_ token: Data) {
        pushRegistration.token = token.map { String(format: "%02x", $0) }.joined()
        pushRegistration.failure = nil
    }

    static func failed(_ error: any Error) {
        pushRegistration.failure = error.localizedDescription
    }

    /// The app is in front: the poll already draws what an agent's push announces. A push about
    /// no agent is the test from the settings screen, which is sent to be seen, and a local post
    /// is only made when the window is not being looked at.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let pushed = notification.request.trigger is UNPushNotificationTrigger
        return pushed && notification.request.content.userInfo["agent"] != nil ? [] : [.banner, .sound]
    }

    /// Approve or deny straight from the notification, the app maybe not even running: the
    /// awaited call is the time the system grants a background action.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        if let item = info["needsYou"] as? String, let action = PushCategory.answer(response.actionIdentifier) {
            await Self.answer(item, action, title: response.notification.request.content.title)
        } else if let agent = info["agent"] as? String {
            NotificationCenter.default.post(name: .openAgent, object: agent)
        }
    }

    /// Its own client off the stored address rather than the `Session`, which a launch in the
    /// background never starts. The shared cookie store carries the login; a 401 spends the stored
    /// password once, like `Session.run`.
    private static func answer(_ item: String, _ action: NeedsYouAction, title: String) async {
        do {
            try await background { try await $0.act(onNeedsYou: item, action) }
        } catch {
            Notifier.post(id: "unanswered:\(item)", title: title, body: "Your answer did not reach the daemon: \(error.localizedDescription)")
        }
    }

    /// One call on a client of its own off the stored address rather than the `Session`, which a
    /// launch in the background never starts. No stored address is nothing to do.
    static func background(_ call: (SchermesClient) async throws -> Void) async throws {
        guard let client = StoredDaemon.client(from: .standard) else { return }
        try await StoredDaemon.run(client, call)
    }
}

#if os(iOS)
/// Hands the daemon this phone's push-to-start token and each running activity's own token,
/// from launch on: a push-to-start wakes the app in the background with no `Session`, and the
/// daemon cannot update or end the activity it started until it hears the new token.
enum LiveActivityTokens {
    private static var watched: Set<String> = []

    static func observe() {
        Task {
            for await token in Activity<AgentActivityAttributes>.pushToStartTokenUpdates {
                await register(token, kind: "start", agent: nil)
            }
        }
        Task {
            for activity in Activity<AgentActivityAttributes>.activities { watch(activity) }
            for await activity in Activity<AgentActivityAttributes>.activityUpdates { watch(activity) }
        }
    }

    private static func watch(_ activity: Activity<AgentActivityAttributes>) {
        guard watched.insert(activity.id).inserted else { return }
        Task {
            for await token in activity.pushTokenUpdates {
                await register(token, kind: "update", agent: activity.attributes.agent)
            }
        }
    }

    private static func register(_ token: Data, kind: String, agent: String?) async {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        try? await NotificationRelay.background { try await $0.registerLiveActivity(token: hex, kind: kind, agent: agent) }
    }
}

#if DEBUG
/// `-schermes.debugActivity YES` starts a local Live Activity at launch, so the lock screen and
/// Dynamic Island views can be looked at on a simulator, where no liveactivity push arrives.
enum DebugActivity {
    static func startIfAsked() {
        guard UserDefaults.standard.bool(forKey: "schermes.debugActivity") else { return }
        do {
            _ = try Activity.request(
            attributes: AgentActivityAttributes(agent: "alpha", label: "Alpha", look: "cloud:teal"),
            content: ActivityContent(
                state: .init(title: "Ship the site", stepsDone: 1, stepsTotal: 3, needsYou: 1, state: "thinking"),
                staleDate: nil
            )
        )
        } catch {
            print("debug activity not started: \(error)")
        }
    }
}
#endif
#endif
