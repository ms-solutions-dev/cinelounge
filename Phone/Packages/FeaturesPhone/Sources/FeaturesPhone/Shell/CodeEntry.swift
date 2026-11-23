import Diagnose
import Foundation
import ProfileKit
import SecondScreen

/// A code from the TV that **the system camera** opened, not the reader in the app.
///
/// **The finding (on-device test 2026-09-27, T3):** the TV shows "Hold your phone to
/// the code", and whoever does that with the iPhone camera got "No usable data". The
/// codes were always URLs (`cinelounge-handoff://…`, `cinelounge-remote://…`), only
/// the app had never registered its schemes with the system. Now the camera offers "Open in
/// CineLounge", and the link lands **in the same flow** as the reader in the
/// app: the same check of the code, the same confirmation before any transfer. There is
/// no second logic. The expiry is not in the code, the TV checks it on
/// acceptance, for the reader as for the camera.
///
/// **A link can come from anywhere**, not only from a camera in front of one's own
/// TV. That changes nothing that did not already apply: a scanned code can also come from
/// a foreign device. Transfer happens only after the confirmation with the table,
/// and only to a device on the same network that knows the key.
enum CodeEntry: Equatable {
    /// Set up a TV: accesses and parental controls over there.
    case handoff(String)
    /// Pair the phone as a remote.
    case remotePairing(String)
    /// Take over a profile that another device hands out (``ProfileKit/ProfileLink``) — the
    /// way from StoryShelf.
    case profile(ProfileLink)
    /// A pairing code (``ProfileKit/Pairing``) — mostly a TV looking for a profile.
    case pairing(String)

    /// What an opened link wants — `nil` for everything that is not a valid code.
    ///
    /// **It is checked here already, not only in the flow.** A broken or foreign
    /// code should not lead the app to a screen that then cannot do anything with
    /// it.
    static func from(_ url: URL, now: Date = Date()) -> CodeEntry? {
        let text = url.absoluteString
        if let link = ProfileLink(text) { return .profile(link) }
        if Pairing.read(text) != nil { return .pairing(text) }
        if HandoffKey.fromText(text, now: now) != nil {
            return .handoff(text)
        }
        if HandoffKey.fromText(text, schema: RemotePairing.schema, now: now) != nil {
            return .remotePairing(text)
        }
        return nil
    }
}

extension ShellModel {

    /// Opens a link from the system camera, see ``CodeEntry``.
    ///
    /// Only the kind is logged, **never the code**: it is a key for as long as it
    /// is valid.
    func open(_ url: URL) {
        switch CodeEntry.from(url) {
        case .handoff(let text):
            Diagnose.step(.login, "Handoff: code opened via the system camera")
            openedHandoffCode = text
            navigator.show(.handoff)
        case .remotePairing(let text):
            Diagnose.step(.network, "Remote: pairing code opened via the system camera")
            navigator.show(.remote)
            Task { await remote.pair(text: text) }
        case .profile(let link):
            Diagnose.step(.login, "Profile: profile link opened via the system camera")
            openedProfileLink = link
            navigator.show(.cloud)
        case .pairing(let text):
            Diagnose.step(.login, "Profile: pairing code opened via the system camera")
            openedPairingCode = text
            navigator.show(.cloud)
        case nil:
            Diagnose.hint(
                .login, "Link opened, but not a valid code (scheme \(url.scheme ?? "–"))")
        }
    }
}
