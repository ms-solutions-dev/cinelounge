import Foundation

/// The identifier on which the App Group, the iCloud container and the shared Keychain group
/// depend (AP85, 2026-11-08).
///
/// Until then `group.dev.ms-solutions.cinelounge` and `iCloud.dev.ms-solutions.cinelounge`
/// were hard-coded. Whoever builds CineLounge with a developer account of their own gets no
/// entitlement for them, however — the app started, found no container and no group. Now
/// everything comes from `CL_BUNDLE_PREFIX` (`Config/Kennungen.xcconfig`), through the
/// Info.plist key `CLKennung` to here.
///
/// **Keychain service names are explicitly not part of it.** They do not depend on the
/// signature, and whoever changes them loses the stored credentials on the devices.
public enum AppIdentifier {

    /// What applies when the Info.plist says nothing — tests, test rigs, an old build.
    public static let preset = "dev.ms-solutions.cinelounge"

    /// `<prefix>.cinelounge` from the Info.plist of the running bundle.
    public static var basis: String { from(Bundle.main.object(forInfoDictionaryKey: "CLKennung")) }

    public static var appGroup: String { "group." + basis }
    public static var cloudContainer: String { "iCloud." + basis }
    /// Behind the team prefix in the entitlements of both targets (see `project.yml`).
    public static var sharedKeychainGroup: String { basis + ".shared" }

    /// An unresolved placeholder (`$(CL_BUNDLE_PREFIX)…`) counts like a missing value.
    static func from(_ value: Any?) -> String {
        guard let text = value as? String, !text.isEmpty, !text.contains("$(") else { return preset }
        return text
    }
}
