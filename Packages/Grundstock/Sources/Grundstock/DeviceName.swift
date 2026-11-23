import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// What this device should be called in the household's device list.
///
/// **The name is the only thing the app contributes (2026-09-12).** Where a device
/// comes from, the server says itself — there is no origin field in the body, because the origin
/// is the address of the request, and an app cannot state it without also being able to
/// state it wrongly. What remains are the device type and this name.
///
/// **And it has a job:** In a list of nothing but "Browser" — that is what the server calls
/// a device without a name — none can be recognized, and signing out becomes guesswork. Anyone who
/// wants to remove a foreign device from their household must be able to name it.
///
/// **`UIDevice.current.name` has not been a device name on iOS since 16**, but the
/// model ("iPhone"), unless the app holds a special entitlement. On tvOS it is
/// still the name the owner set ("Wohnzimmer"). Both are usable:
/// the TV is named after its room, the phone after its model — and for the
/// latter the person's name is added at sign-in anyway.
public enum DeviceName {

    /// The name of this device.
    ///
    /// **`@MainActor`, because `UIDevice.current` is.** It is read on pairing and
    /// on sign-in, and both happen in a view — there the binding costs
    /// nothing. An `assumeIsolated` would only have made the same warning invisible.
    @MainActor
    public static var thisDevice: String {
        #if canImport(UIKit)
            let reported = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reported.isEmpty { return reported }
        #endif
        return fallback
    }

    /// When the system yields nothing.
    ///
    /// **By platform and not "device".** A household has one TV and
    /// several phones; "device" does not separate them, "Apple TV" and "iPhone" do.
    private static var fallback: String {
        #if os(tvOS)
            "Apple TV"
        #elseif os(iOS)
            "iPhone"
        #else
            "Rechner"
        #endif
    }
}
