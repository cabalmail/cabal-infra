// Push notifications ship on iOS and macOS; visionOS is deliberately
// excluded (project.yml destination-filters the NSE the same way), so the
// guards are explicit `os(...)` checks rather than `canImport(...)` — the
// visionOS build of the shared Cabalmail target must not compile this.
#if os(iOS) || os(macOS)
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import UserNotifications
import CoreSpotlight
import CabalmailKit

#if os(iOS)
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
        PushRegistrar.shared.deviceTokenDidChange(Self.hexToken(deviceToken))
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
#else
/// AppKit app delegate for the macOS target, installed via
/// `@NSApplicationDelegateAdaptor` in `CabalmailMacApp` — the AppKit twin
/// of the iOS class above, existing for the same reason: APNs token
/// callbacks land on `NSApplicationDelegate` and the notification-center
/// delegate must be wired before launch finishes, so
/// `applicationWillFinishLaunching` (the earliest AppKit hook) does the
/// wiring. Everything else stays in SwiftUI land.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        PushRegistrar.registerNotificationCategories()
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushRegistrar.shared.deviceTokenDidChange(Self.hexToken(deviceToken))
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Unsigned / entitlement-less local builds land here on every
        // launch; signed builds only on APNs connectivity trouble. Either
        // way the app works fine without push, so log and move on.
        CabalmailLog.warn("Push", "remote-notification registration failed: \(error)")
    }

    /// Silent-push entry point. The server sends Macs a background push
    /// (`content-available: 1` plus `msgRef`, no alert) because alert
    /// pushes could not be enriched: the NSE is killed by usernoted before
    /// it runs, and `willPresent` — the previous in-app fallback — is only
    /// called while the app is frontmost. A *running* app (any focus)
    /// receives the silent push here, fetches the envelope, and posts an
    /// enriched local notification; macOS's normal foreground rule then
    /// handles presentation via `willPresent` below. A quit app receives
    /// nothing — the accepted trade; iOS covers that case.
    ///
    /// The class is main-actor isolated, so this hops off via `Task` for
    /// the network work; `PushRegistrar` is itself @MainActor.
    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        guard let ref = PushMessageRef(userInfo: userInfo) else {
            CabalmailLog.warn("Push", "silent push without a parseable msgRef; ignored")
            return
        }
        Task {
            if await !PushRegistrar.shared.presentEnrichedNotification(for: ref) {
                // Enrichment failed (no session, fetch error): degrade to
                // the generic "New mail" a legacy alert push would have
                // shown, rather than dropping the notification silently.
                await PushRegistrar.shared.presentGenericNotification(for: ref)
            }
        }
    }

    /// Spotlight-result continuation. On macOS this AppKit callback is the
    /// only reliable delivery path — SwiftUI's `.onContinueUserActivity`
    /// never fires for `CSSearchableItemActionType` here (see
    /// `SpotlightRouter`). iOS keeps the SwiftUI path and does not
    /// implement the UIKit equivalent.
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType else { return false }
        SpotlightRouter.shared.handle(userActivity)
        return true
    }
}
#endif

extension AppDelegate {
    /// Hex-encodes the raw APNs token, the wire format `/push_register`
    /// stores. Shared by both platform delegates above.
    static func hexToken(_ deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }
}

// The UN delegate methods are called on an arbitrary queue, and the
// protocol declares them nonisolated — without the explicit `nonisolated`
// they'd inherit the class's application-delegate-inferred @MainActor
// isolation and trip strict concurrency (non-Sendable UN* parameters can't
// cross into an isolated witness). Sendable values are extracted up front;
// only those hop to the main actor. Shared verbatim by iOS and macOS.
extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Foreground delivery. On iOS (and while the Mac app is frontmost) the
    /// polling-driven UI already shows the new message, so a banner would
    /// double-notify — play the sound only.
    ///
    /// No enrichment happens here anymore: macOS only calls `willPresent`
    /// while the app is frontmost, so the #654 enrich-on-present branch was
    /// unreachable exactly when it mattered (running but unfocused).
    /// Enrichment moved to `didReceiveRemoteNotification` above, which fires
    /// for a running app regardless of focus; what lands here is the enriched
    /// local notification it posts (or a legacy alert push from an old server
    /// during rollout, which presents generically).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        #if os(macOS)
        // Active: the UI already shows the mail, so sound only. Inactive:
        // full banner — this is what presents our own local notifications
        // while the app runs unfocused.
        let isActive = await MainActor.run { NSApp.isActive }
        return isActive ? [.sound] : [.banner, .sound]
        #else
        return [.sound]
        #endif
    }

    /// Action dispatch (notification buttons and the default tap). The async
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
