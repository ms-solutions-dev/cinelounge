import Core
import Foundation

/// "Ratings the app does not understand count as blocked" — **the switch, and
/// for both programs.**
///
/// **Why this is its own building block and not a `Bool` in two places** (AP40,
/// 2026-09-20): Exactly the same trap as with ``AgeLimit``, only one floor deeper. The
/// name `childLock.blockUnknown` existed in **both** programs — on the TV as the
/// string `"1"` in the Keychain, on the phone as a `Bool` in `UserDefaults`. Two
/// callers that spell the same key themselves can disagree about its type
/// and its location; two callers of the same method cannot.
///
/// **And the default is `true`, not `false`.** A missing value means "not yet
/// decided", and for a parental control the undecided answer is the
/// cautious one: What the app cannot interpret it does not show to a child. `Bool`'s
/// default value would be the dangerous direction here — that is why the question lives here and
/// not in an `store.bool(forKey:)` at the caller.
public enum UnrecognizedLock {

    /// **The same key in both programs**, verbatim.
    ///
    /// **Not a language key but a store key** — `scripts/strings.py`
    /// recognises this by the namespace `childLock.`.
    public static let storeKey = "childLock.blockUnknown"

    /// Whether ratings that are not understood are blocked — **one compartment alone.** Without an entry: **yes.**
    ///
    /// **For the device base level (`profile == nil`) this is the answer; for a profile it is
    /// a trap** (thread G, 2026-09-25). With "either one blocks", a profile
    /// without an entry always meant "blocked", and the device switch "off" never took effect again once
    /// a profile was active. Whoever needs the rule for a person asks
    /// ``applicable(from:forItem:)``; whoever wants to know what is set **on the profile**, ``own(from:forItem:)``.
    public static func read(from store: any KeyValueStore, forItem profile: String? = nil) -> Bool {
        own(from: store, forItem: profile) ?? true
    }

    /// What is **explicitly** in this compartment — `nil` if nothing.
    ///
    /// **Unset is not an answer here but the absence of the question.** A profile
    /// at which nobody ever set "block what is not understood" says nothing — and then
    /// the device decides (``forItem(profile:device:)``).
    public static func own(from store: any KeyValueStore, forItem profile: String?) -> Bool? {
        let key = ProfileSlot.key(storeKey, forItem: profile)
        guard let raw = try? store.value(for: key) else { return nil }
        return raw == "1"
    }

    /// The rule from profile and device — **either one blocks, but only if it
    /// says something.**
    ///
    /// * The profile blocks only with an **explicit** yes. Without an entry it is silent.
    /// * The device blocks with yes **or without an entry** — there the cautious
    ///   default stays in place, because a device at which nobody ever asked is undecided.
    ///
    /// **An explicit no on the profile does not open a device that says yes.** The question is
    /// a yes or no, and the cautious answer wins — the same direction as
    /// ``AgeLimit/forItem(profile:device:)``, only for a truth value.
    ///
    /// - Parameters:
    ///   - profil: ``own(from:forItem:)`` of the profile, `nil` means not set.
    ///   - geraet: ``read(from:forItem:)`` of the device base level, that is including the default.
    public static func forItem(profile: Bool?, device: Bool) -> Bool {
        profile == true || device
    }

    /// ``forItem(profile:device:)`` directly from the store — **the question that a rule asks.**
    ///
    /// - Parameter profil: Who is sitting in front of it; `nil` means: the device base level alone.
    public static func applicable(from store: any KeyValueStore, forItem profile: String?) -> Bool {
        forItem(
            profile: profile.flatMap { own(from: store, forItem: $0) },
            device: read(from: store, forItem: nil))
    }

    /// Stores the switch.
    ///
    /// **`"1"` and `"0"` and not `true`/`false`:** The store carries strings, and
    /// every language reads a number the same way. The TV has always written it that way; a
    /// second format here would mean that a transferred value counts on the other side as
    /// "not set" — and that would fall into the default, so silently into the
    /// other answer.
    public static func write(
        _ on: Bool, in store: any KeyValueStore, forItem profile: String? = nil
    ) {
        try? store.set(on ? "1" : "0", for: ProfileSlot.key(storeKey, forItem: profile))
    }
}
