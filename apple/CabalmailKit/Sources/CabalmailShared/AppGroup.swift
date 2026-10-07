import Foundation

/// The App Group the apps share with their extensions: a `UserDefaults`
/// suite (and file container) the apps write and the extensions read.
///
/// Six entitlements files also declare it as a literal, since a plist can't
/// import a module. Nothing checks those copies, so change them by hand with
/// this one. `PushHandoffContractTests` pins this constant to the shipped
/// value, so a change here fails the Kit tests instead of quietly cutting
/// every handoff.
public enum AppGroup {
    public static let identifier = "group.com.cabalmail.Cabalmail"
}
