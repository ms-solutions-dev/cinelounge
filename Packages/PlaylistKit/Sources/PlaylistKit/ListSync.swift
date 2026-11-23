import Core
import Foundation

/// The channel lists of this device as ``Core/ChannelListAccess`` — and back.
///
/// **The seam between list and cloud** (AP43). ``ProfileKit/ChannelListMapping`` maps
/// the access onto records and does not know `PlaylistKit`; this is where the other
/// half lives, and it does not know CloudKit. Between the two lies a plain value.
///
/// **The secret is assembled in exactly one place and taken apart again in exactly
/// one.** For Xtream it is the password, for M3U the full address —
/// there it sits as a query parameter. If this rule stood in two places, it would
/// be wrong in one of them, and then a password would sit in plain text in the cloud.
extension PlaylistStore {

    /// What is to go up from this device.
    ///
    /// **A list without a secret goes along anyway.** On the second device it cannot
    /// be signed in, but it is there — and the viewer sees that it is missing,
    /// instead of it not appearing at all.
    public func channelListCredentials() -> [ChannelListAccess] {
        playlists.map { list in
            switch list.kind {
            case .xtream(let server, let user):
                ChannelListAccess(
                    key: list.key, name: list.name, kind: .xtream,
                    address: server, user: user, epg: list.epgURL,
                    active: list.isEnabled, secret: password(for: list.id))
            case .m3u(let address):
                ChannelListAccess(
                    key: list.key, name: list.name, kind: .m3u,
                    // **Without the query part**, because that is where the password sits.
                    address: ChannelListAccess.pending(address),
                    user: ChannelListAccess.user(from: address) ?? "",
                    epg: list.epgURL, active: list.isEnabled,
                    secret: address.absoluteString)
            case .jellyfinLiveTV:
                ChannelListAccess(
                    key: list.key, name: list.name, kind: .jellyfin,
                    epg: list.epgURL, active: list.isEnabled)
            }
        }
    }

    /// What came from the cloud — **additive and not replacing.**
    ///
    /// **Nothing is deleted here**, and that is a decision: A list that is on
    /// this device and not in the cloud can mean two things — "another
    /// device removed it" or "it was just created here and is not up yet".
    /// The two cannot be told apart here, and the wrong answer takes
    /// someone's provider away. Removal remains an action on the device.
    ///
    /// - Returns: how many lists were added or changed.
    @discardableResult
    public func adopt(_ credentials: [ChannelListAccess]) -> Int {
        var counted = 0
        for credential in credentials {
            guard let category = kind(from: credential) else { continue }
            if let available = playlists.first(where: { $0.key == credential.key }) {
                guard available.name != credential.name || available.isEnabled != credential.active
                else { continue }
                rename(available.id, to: credential.name)
                setEnabled(credential.active, for: available.id)
                counted += 1
                continue
            }
            let list = Playlist(
                id: credential.key, name: credential.name, kind: category,
                isEnabled: credential.active, epgURL: credential.epg)
            // **The password goes along with the creation.** ``add(_:password:)`` writes
            // credentials anyway as soon as the kind carries a username — a
            // follow-up afterwards would be a second write to the same row.
            add(list, password: credential.secret)
            counted += 1
        }
        // **The other store instances re-read** (AP43). What arrives here comes from the
        // sync and not from a screen; without this call the new list would sit
        // in the Keychain and appear in the UI only at the next start. The
        // reason why there are several store instances is given at ``ListGuard``.
        if counted > 0 { ListGuard.call() }
        return counted
    }

    /// The kind of a list from the access — **without a secret no M3U list.**
    ///
    /// For M3U the secret *is* the address; without it there would be nothing to create. For
    /// Xtream only the password is missing then, and the list is still a list.
    private func kind(from credential: ChannelListAccess) -> Playlist.Kind? {
        switch credential.kind {
        case .xtream:
            guard let server = credential.address else { return nil }
            return .xtream(server: server, username: credential.user)
        case .m3u:
            guard let full = credential.secret.flatMap(URL.init(string:)) else { return nil }
            return .m3u(full)
        case .jellyfin:
            return .jellyfinLiveTV
        }
    }
}
