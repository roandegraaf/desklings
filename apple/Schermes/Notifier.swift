import Foundation
import UserNotifications
#if os(iOS)
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
        guard !asked else { return }
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

    static func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func badge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count)
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

    /// The app is in front: the poll already draws what this announces.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if let agent = response.notification.request.content.userInfo["agent"] as? String {
            NotificationCenter.default.post(name: .openAgent, object: agent)
        }
    }
}
