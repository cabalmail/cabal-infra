import Foundation
import Synchronization

/// What became of the app's settings push when the feed queue asked for it
/// (`RssUnsentSettingsPush`).
///
/// The server refuses a flag add for a slot its copy of the palette does
/// not hold. Usually the flag was deleted, here or on another device, and
/// the queue drops the add (the maintainer, 2026-11-11). But a flag created
/// while the settings push failed is in this device's palette and not yet
/// in the server's, so the refusal says only that the settings have not
/// gone yet (#2421). The queue asks before it drops anything.
public enum RssUnsentSettings: Sendable, Equatable {
    /// No settings change was waiting: the server's palette is this
    /// device's, so the refusal stands.
    case nothingUnsent
    /// A settings change was waiting and the server has it now: the
    /// refused adds may go through if sent again.
    case sent
    /// A settings change is waiting and could not be sent: the server may
    /// not know the flag yet, so the adds wait too.
    case stillUnsent
}

/// Sends the settings change this device has not managed to send, if any,
/// and says how that went. Set by the app on `RssSyncEngine` when it wires
/// a session; the Kit knows nothing else of preferences.
public typealias RssUnsentSettingsPush = @Sendable () async -> RssUnsentSettings

/// The engine's one `RssUnsentSettingsPush`, shared with its drain. Set and
/// read from any isolation domain, so the app can install it while it
/// wires the session, before any drain can run.
final class RssUnsentSettingsHook: Sendable {
    private let push = Mutex<RssUnsentSettingsPush?>(nil)

    func set(_ push: RssUnsentSettingsPush?) {
        self.push.withLock { $0 = push }
    }

    /// Asks for the push; `.nothingUnsent` when nobody has installed one.
    func ask() async -> RssUnsentSettings {
        guard let push = push.withLock({ $0 }) else { return .nothingUnsent }
        return await push()
    }
}
