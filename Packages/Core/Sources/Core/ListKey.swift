import Foundation

/// The key under which the state of a channel list is stored.
///
/// **Until now the list identifier was a random number per device** (`UUID().uuidString`, assigned
/// on entry). It stands at the front of every Xtream title identifier, in the key of the last
/// watched channel and in every channel identifier of an M3U file. As long as the state never
/// left the device, that went unnoticed; with AP42 it does. The same provider, entered on
/// two devices, produced two random numbers — and the film one
/// had half-watched upstairs would be a title that does not exist downstairs.
///
/// **The key therefore comes from what the list is**, and not from what the
/// device once drew for it: hostname and username. Both devices compute
/// the same thing without agreeing on it.
///
/// **The password is never in it.** The key travels into files, into a backup
/// and later to iCloud (AP43); an M3U address, however, carries the password as a
/// query parameter. Taking the address raw would have been the convenient way and would have
/// carried a provider password into each of these stores — see ``forItem(_:)``.
public enum ListKey {

    /// Computes the key from the kind of a list.
    ///
    /// - Xtream: `xtream|host|user`. **Without the port**, because a provider offers the same
    ///   access on several (80, 8080, 25461) and a change among them is not a
    ///   different access. Anyone who included the port would lose the state at every
    ///   switch — silently, because both addresses answer.
    /// - M3U: `m3u|host|user` if the address carries a user as a query parameter
    ///   (the usual `get.php` form of a panel), otherwise `m3u|host|path`. The
    ///   query is dropped entirely — the password is in it.
    /// - Jellyfin: `jellyfin`. There is exactly one channel management per server, and which
    ///   server that is stands at the profile's access and not at the list.
    public static func forItem(_ kind: Playlist.Kind) -> String {
        switch kind {
        case .xtream(let server, let username):
            "xtream|\(calculator(server))|\(username.lowercased())"
        case .m3u(let url):
            "m3u|\(calculator(url))|\(identifier(from: url))"
        case .jellyfinLiveTV:
            "jellyfin"
        }
    }

    /// Whether an identifier originates from here — **the question of the re-keying.**
    ///
    /// An identifier that does not originate from here is one of the old random numbers and must be
    /// rewritten. The form is checked and not the exact value: A list
    /// whose address has changed carries a computed key that no longer matches its
    /// current kind — that is a move and not legacy data.
    public static func isComputed(_ identifier: String) -> Bool {
        identifier == "jellyfin" || identifier.hasPrefix("xtream|") || identifier.hasPrefix("m3u|")
    }

    /// The hostname, lowercase. **Without a hostname the whole text** — an
    /// address without a host (`file:///…`) is a local file, and its path is the
    /// only thing that distinguishes it.
    private static func calculator(_ url: URL) -> String {
        guard let host = url.host(), !host.isEmpty else { return "" }
        return host.lowercased()
    }

    /// The user from the query — or the path.
    ///
    /// **The query is never taken along, only one field is read from it.** `get.php` carries
    /// `username`, `password` and `type`; of the three only the first says
    /// *whose* list this is. The other two change without the list
    /// becoming a different one — and the password has no business in a key anyway.
    private static func identifier(from url: URL) -> String {
        let split = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let user = split?.queryItems?.first(where: { $0.name.lowercased() == "username" })?
            .value, !user.isEmpty
        {
            return user.lowercased()
        }
        let path = url.path()
        return path.isEmpty ? "/" : path
    }
}
