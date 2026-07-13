#if os(iOS)
import UIKit
import UserNotifications
import CabalmailKit

/// UIKit app delegate for the iOS target, installed via
/// `@UIApplicationDelegateAdaptor` in `CabalmailApp`. Exists solely for the
/// push-notification surface — APNs token callbacks land here (there is no
/// SwiftUI-native equivalent), and the `UNUserNotificationCenter` delegate
/// must be wired before `didFinishLaunching` returns so a notification that
/// launched the app is delivered. Everything else stays in SwiftUI land.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        PushRegistrar.registerNotificationCategories()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        PushRegistrar.shared.deviceTokenDidChange(tokenHex)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Simulator / entitlement-less builds land here on every launch;
        // real devices only on APNs connectivity trouble. Either way the
        // app works fine without push, so log and move on.
        CabalmailLog.warn("Push", "remote-notification registration failed: \(error)")
    }
}

// The UN delegate methods are called on an arbitrary queue, and the
// protocol declares them nonisolated — without the explicit `nonisolated`
// they'd inherit the class's UIApplicationDelegate-inferred @MainActor
// isolation and trip strict concurrency (non-Sendable UN* parameters can't
// cross into an isolated witness). Sendable values are extracted up front;
// only those hop to the main actor.
extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Foreground delivery: the IDLE-driven UI already shows the new
    /// message, so a banner would double-notify — play the sound only.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.sound]
    }

    /// Action dispatch (lock-screen buttons and the default tap). The async
    /// variant's return *is* the completion handler, so returning only after
    /// `handleNotificationAction` resolves keeps the system's background
    /// budget honest for MARK_READ / ARCHIVE.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.actionIdentifier
        let ref = PushMessageRef(userInfo: response.notification.request.content.userInfo)
        await PushRegistrar.shared.handleNotificationAction(identifier: identifier, ref: ref)
    }
}
#endif
