import Foundation

/// A way by which a ``ProfileKit`` gets to content.
///
/// **Three ways and one concept** (AP41, 2026-09-21). Until here they were three things with
/// three owners: The media-server user was called "account" and lay in the Keychain, the
/// channel lists hung on the **device** and applied to whoever sat in front, and the
/// portal person was a login via a device attribute. Whoever switched the account
/// switched the first and neither of the other two.
///
/// **What is recorded here is *what belongs to whom* — not what is secret.** Password and access token
/// stay in the Keychain; this type carries the **ID** under which they are
/// found there. Otherwise a password would sit in a file that every backup takes along, and
/// from AP43 at the latest in the cloud.
public enum Access: Sendable, Equatable, Hashable, Codable {
    /// Stored case names keep their original (German) form — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case jellyfin
        case channelList = "senderliste"
        case portals = "portale"
    }

    /// Stored keys of ``jellyfin`` keep their original (German) names (AP85 B4).
    private enum JellyfinCodingKeys: String, CodingKey {
        case server
        case userID = "benutzerkennung"
        case username = "benutzername"
    }

    /// Stored keys of ``channelList`` keep their original (German) names (AP85 B4).
    private enum SenderlisteCodingKeys: String, CodingKey {
        case identifier = "kennung"
    }

    /// A user of a media server.
    ///
    /// **Server and user ID together** — the same human on two servers is
    /// two accesses, two humans on one server too. The display name is included
    /// because otherwise nobody knows it anymore: Without a connection to the server there would be only an
    /// ID, and the switcher would show a row of numbers.
    case jellyfin(server: URL, userID: String, username: String)

    /// A channel list — **via its ID and not via its content.**
    ///
    /// The list itself is managed by ``PlaylistKit/PlaylistStore``, including the password in the
    /// secret slot. Here it only says **whose** list it is. Without this record it would
    /// remain a matter of the device, and a child profile would see the parents' channels.
    case channelList(identifier: String)

    /// The portals — **and, if the server knows persons, which of them.**
    ///
    /// **Two cases in one, because there are two kinds of counterpart.** A bare bridge
    /// knows no persons: Every device on the network sees everything, and then `person` is empty.
    /// Then the old sentence still applies, verbatim from ``Core/AccountState/hasPortals``:
    /// *A wish and not an access* — what a portal is, the bridge knows; where it
    /// stands is a setting of the device (``Core/BridgeAddress``); what the person
    /// decides is **whether they want it**.
    ///
    /// **On the CineLounge server it is an access.** It knows a household, and a
    /// device that belongs to no person — the living-room TV — names on every
    /// request the profile currently sitting in front (`X-CL-Profile`). This ID used to
    /// sit as `setup.deviceProfile` on the **device**: It applied to whoever sat in front,
    /// and no account switch ever changed it. Here it hangs on the person,
    /// and ``ProfileSwitch`` sets it in the same step as the media-server session.
    case portals(person: String?)

    /// Which kind of access this is — **for the questions that do not depend on the content.**
    ///
    /// A `switch` over the whole case at every place that only wants to know "is this the
    /// media server?" ties two lines to fields it does not read —
    /// and has to be touched as soon as a case gets a field.
    public enum Kind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        case jellyfin
        case channelList = "senderliste"
        case portals = "portale"
    }

    public var kind: Kind {
        switch self {
        case .jellyfin: .jellyfin
        case .channelList: .channelList
        case .portals: .portals
        }
    }

    /// Whether there may be only **one** of this kind per profile.
    ///
    /// The media server, because "Continue Watching" comes from one server and two accesses
    /// would be two truths about the same state. The portals, because they are a wish
    /// and one cannot wish the same thing twice. Channel lists, on the other hand, have no
    /// state they could contradict — several of them are the normal case.
    var onlyOnce: Bool { kind != .channelList }

    /// The ID under which the **old** account list kept this access.
    ///
    /// `server|user` — the same format that ``ParentalControls/ChildAccountList``
    /// still stores as a token today. **It is here only for the migration:** Without it
    /// ``ProfileBook/adopt(jellyfin:children:channelLists:wantsPortals:signedIn:fallbackName:)``
    /// would have to rebuild the form of the old ID, and then it would be in a second place
    /// and stay there when the first changes.
    ///
    /// `nil` for everything that is not a media-server user — the old list knew only
    /// those.
    public var legacyAccountID: String? {
        switch self {
        case .jellyfin(let server, let user, _): "\(server.absoluteString)|\(user)"
        case .channelList, .portals: nil
        }
    }

    /// The channel list's ID, if it is one.
    ///
    /// **The counterpart to ``legacyAccountID``, and here for the same reason:** Whoever wants to
    /// filter a profile's lists out of ``PlaylistKit/PlaylistStore`` needs
    /// the IDs as a set. A `case .channelList(let identifier)` at every such
    /// place ties the caller to the shape of the case.
    public var channelListID: String? {
        switch self {
        case .channelList(let identifier): identifier
        case .jellyfin, .portals: nil
        }
    }

    /// The display name, if the access carries one.
    ///
    /// `nil` means: This kind has no name of its own, and the UI should set its
    /// own text — an invented name ("Portals") at this place would be a
    /// language key in the model.
    public var displayName: String? {
        switch self {
        case .jellyfin(_, _, let name): name
        case .channelList, .portals: nil
        }
    }
}
