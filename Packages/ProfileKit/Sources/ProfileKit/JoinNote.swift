import Core
import CryptoKit
import Foundation

/// What **this device** knows about its joining — an open request and the token it came
/// in with (AP47).
///
/// **In the Keychain, and everything in it is either a secret or a digest of one.**
/// The request token is the only credential with which the device token is picked up after
/// approval; whoever has it gets it. The two token fields carry only the
/// ``PersonMarker/digest`` — they answer "the same token?" and nothing else.
///
/// **Per device and not per profile**, like ``Core/DeviceTrait``: the device is what
/// signs in. Which profile asked is stored anyway — the approval belongs to it, even if
/// another profile is now in front of the device.
///
/// **Here in the `ProfileKit` package and not with the views**, although only they use it: the
/// keys have the form of language keys, and `scripts/strings.py` reports every such string
/// from an unknown namespace that appears in the UI layers as an error.
public struct JoinNote: Sendable {

    static let requestKey = "beitritt.anfrage"
    static let requestProfileKey = "beitritt.anfrageprofil"
    static let requestMarkerKey = "beitritt.anfragemerkmal"
    static let usedKey = "beitritt.markeGenutzt"
    static let failedKey = "beitritt.markeGescheitert"
    static let signedOutKey = "beitritt.markeAbgemeldet"
    static let revocationKey = "beitritt.widerrufOffen"

    private let keychain: any KeyValueStore

    public init(_ keychain: any KeyValueStore) {
        self.keychain = keychain
    }

    private func read(_ key: String) -> String? {
        guard let value = try? keychain.value(for: key), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func write(_ value: String?, _ key: String) {
        if let value, !value.isEmpty {
            try? keychain.set(value, for: key)
        } else {
            try? keychain.remove(key)
        }
    }

    // MARK: - The open request

    /// The request token of an open request and the profile that asked.
    ///
    /// **Both or nothing.** A request without a profile would not know after approval where
    /// access and token belong; silently giving it to the currently active one would mean the
    /// access lands with whoever happens to be sitting in front of the device.
    public var openRequest: (request: String, profile: Profile.Identifier)? {
        guard let request = read(Self.requestKey),
            let profile = read(Self.requestProfileKey)
        else { return nil }
        return (request, Profile.Identifier(rawValue: profile))
    }

    /// - Parameter merkmal: the device token that was already there when asking — one rejected
    ///   by the server, say. Only its digest is stored (``mayReplace(_:)``).
    public func rememberRequest(
        _ request: String, forItem profile: Profile.Identifier, trait: String? = nil
    ) {
        write(request, Self.requestKey)
        write(profile.rawValue, Self.requestProfileKey)
        write(trait.map(Self.digest), Self.requestMarkerKey)
    }

    /// The request is decided or expired — **then it no longer applies**, and asking again
    /// would mean mistaking someone else's question for one's own.
    ///
    /// **Any sign-in by another route clears it too** (check 2026-09-27, B1) — via
    /// ``Household/DeviceSignIn/create(_:own:in:)`` and ``Household/PortalSignOut``.
    public func forgetRequest() {
        write(nil, Self.requestKey)
        write(nil, Self.requestProfileKey)
        write(nil, Self.requestMarkerKey)
    }

    /// Whether an approval may replace the token that is on the device **now**.
    ///
    /// **Yes, if none is there or it is still the same as when asking** — a rejected token,
    /// say, after which someone asked for admission. **No, if another one has arrived in the
    /// meantime** (check 2026-09-27, B1): then the device was signed in by another route, by
    /// code, invitation or PIN, and a late-collected approval would silently turn a shared TV
    /// into one person's device. A note from before this slot carries no digest and counts as
    /// "none was there when asking".
    public func mayReplace(_ trait: String?) -> Bool {
        guard let trait else { return true }
        return read(Self.requestMarkerKey) == Self.digest(trait)
    }

    /// A SHA-256 of the token — **the secret does not sit twice in the Keychain.**
    static func digest(_ trait: String) -> String {
        SHA256.hash(data: Data(trait.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The token this device came in with

    /// The digest of the token with which this device was last signed in.
    ///
    /// **The yardstick for "the profile now holds a new token".** After a revocation every
    /// device that came in through the old one falls; if the token in the profile differs from
    /// this one, the new one is there, and the device signs in silently with it. If they are
    /// equal, a sign-in would only be the same attempt again.
    public var used: String? { read(Self.usedKey) }

    public func rememberUsed(_ tag: PersonMarker) {
        write(tag.digest, Self.usedKey)
        // A token that has just worked has not failed — and a new approval cancels a sign-out.
        if failed == tag.digest { write(nil, Self.failedKey) }
        write(nil, Self.signedOutKey)
    }

    /// The digest of the token with which **someone here explicitly signed out**.
    ///
    /// **Without this lock, signing out would be ineffective:** token gone, token still in the
    /// profile — the next time the portals open, the device would silently sign in again, each
    /// time as a new server device, until the ten per token are full. Only this one token is
    /// locked; a new approval (``rememberUsed(_:)``) or another token in the profile opens the
    /// way again.
    public var signedOut: String? { read(Self.signedOutKey) }

    public func rememberSignedOut(_ tag: PersonMarker) {
        write(tag.digest, Self.signedOutKey)
    }

    /// The digest of a token that the server rejected as unknown.
    ///
    /// **The brake against the loop:** this token is never tried again — only another one in
    /// the profile opens the way. Otherwise every opening of the portals would ask the server
    /// with the same dead token until its throttle strikes.
    public var failed: String? { read(Self.failedKey) }

    public func rememberFailed(_ tag: PersonMarker) {
        write(tag.digest, Self.failedKey)
    }

    // MARK: - Widerrufe, die noch nicht beim Server waren

    /// The profiles whose person token is to be revoked but whose revocation the server has not
    /// yet heard about (AP47, 2026-09-25).
    ///
    /// **Sharing has already ended in CloudKit when the revocation fails** — without a network
    /// to the home server, say. Without this note the old token would stay valid, and the
    /// foreign TV would keep signing in with it; the condition under which decision (A) holds
    /// would be silently broken. The next sync catches up.
    ///
    /// **A set and not a slot** (counter-check strand D, finding 2.1b): with a slot, the second
    /// failed revocation overwrote the first, and its token stayed valid forever. An older
    /// state with only one ID is read as a set of one.
    public var openRevocations: [Profile.Identifier] {
        guard let text = read(Self.revocationKey) else { return [] }
        if let list = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) {
            return list.map { Profile.Identifier(rawValue: $0) }
        }
        return [Profile.Identifier(rawValue: text)]
    }

    private func writeRevocations(_ list: [Profile.Identifier]) {
        guard !list.isEmpty,
            let data = try? JSONEncoder().encode(list.map(\.rawValue))
        else {
            write(nil, Self.revocationKey)
            return
        }
        write(String(decoding: data, as: UTF8.self), Self.revocationKey)
    }

    public func rememberRevocation(_ identifier: Profile.Identifier) {
        var list = openRevocations
        guard !list.contains(identifier) else { return }
        list.append(identifier)
        writeRevocations(list)
    }

    /// A revocation has reached the server — or has become moot (profile deleted or turned
    /// into a child profile).
    public func forgetRevocation(_ identifier: Profile.Identifier) {
        writeRevocations(openRevocations.filter { $0 != identifier })
    }
}
