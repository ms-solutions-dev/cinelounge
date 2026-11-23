import Foundation

/// A channel list as it can travel through the cloud.
///
/// **A value of its own and not ``Playlist``**, and it lives **here** and not in
/// ``ProfileKit/ChannelListMapping``, which maps it to records: That way ``PlaylistKit`` can
/// produce it without pulling CloudKit along — the same rule that keeps `CloudSync` out of
/// `Core`, because `TopShelf` depends on `Core` and on nothing else.
///
/// **What is secret sits in one field**, and in exactly one: ``secret``. With an Xtream
/// access that is the password, with an M3U address the **full address** — there the password
/// sits as a query parameter, which is exactly why ``address`` carries it without. The
/// reasoning has stood at ``Core/ListKey`` since AP42: The key travels into files,
/// backups and now to iCloud.
public struct ChannelListAccess: Sendable, Equatable, Hashable {

    public enum Kind: String, Sendable, Equatable, Hashable, CaseIterable {
        case xtream
        case m3u
        case jellyfin
    }

    /// The list key from AP42 — **also the record name.**
    public let key: String
    public let name: String
    public let kind: Kind
    /// The address **without query part**; empty for `jellyfin`.
    public let address: URL?
    public let user: String
    public let epg: URL?
    public let active: Bool
    /// Password (Xtream) or the full address (M3U) — **only encrypted.**
    public let secret: String?

    public init(
        key: String, name: String, kind: Kind, address: URL? = nil, user: String = "",
        epg: URL? = nil, active: Bool = true, secret: String? = nil
    ) {
        self.key = key
        self.name = name
        self.kind = kind
        self.address = address
        self.user = user
        self.epg = epg
        self.active = active
        self.secret = secret
    }

    /// The address without query part — **what may be stored openly.**
    ///
    /// An M3U address carries user and password as query parameters. Storing it in plain text
    /// would mean storing the password in plain text; the full address belongs in the encrypted
    /// field. The same reasoning as at ``ListKey`` — except that here the value really
    /// goes to iCloud.
    public static func pending(_ address: URL) -> URL {
        var split = URLComponents(url: address, resolvingAgainstBaseURL: false)
        split?.query = nil
        split?.fragment = nil
        return split?.url ?? address
    }

    /// The user name from an M3U address, if it carries one.
    ///
    /// **For display only.** Sign-in uses the full address; this name is in the access so that
    /// the second device does not show "List" without any information.
    public static func user(from address: URL) -> String? {
        let split = URLComponents(url: address, resolvingAgainstBaseURL: false)
        let value = split?.queryItems?
            .first { $0.name.lowercased() == "username" }?.value
        return (value?.isEmpty ?? true) ? nil : value
    }
}
