import Core
import Foundation

/// The complete access point of a provider using the Xtream protocol.
///
/// Server **and** credentials together — unlike
/// ``XtreamCredentials``, which carries only username and password and is stored
/// separately. Separating the two has a reason: The server is in the
/// list and may appear in a backup, the password may not.
///
/// The protocol is plain: One address, one username, one password, and
/// everything runs via `player_api.php` with a parameter saying what you want to know.
/// Compared with an M3U file it has two advantages — the categories come along
/// structured, and movies and series are separated from the channels.
///
/// **The password is in every address.** That is a peculiarity of the protocol
/// and cannot be changed: Even a channel's address contains it in plain text.
/// Therefore one rule applies throughout here — see ``redacted(_:)``: Nothing that
/// contains an address may go unfiltered into a log line or
/// error message. A log travels into error reports, and the
/// account would be given away.
public struct XtreamEndpoint: Sendable, Equatable {

    public let server: URL
    public let username: String
    public let password: String

    /// - Parameter server: Address with or without scheme, with or without
    ///   trailing slash. Both occur, and both have to work.
    public init?(server rawServer: String, username: String, password: String) {
        guard let normalized = Self.normalize(rawServer) else { return nil }
        guard !username.isEmpty, !password.isEmpty else { return nil }

        self.server = normalized
        self.username = username
        self.password = password
    }

    /// For an already checked address — say from the store, where it was
    /// already normalized on entry.
    ///
    /// Without this path a stored address would have to go through the normalization
    /// again on every load, and an error there would make a stored
    /// account unusable.
    public init(server: URL, username: String, password: String) {
        self.server = server
        self.username = username
        self.password = password
    }

    /// Brings a typed address into a usable form.
    ///
    /// What users enter and what has to arrive here are far apart:
    /// `server.de:8080`, `http://server.de:8080/`, `SERVER.DE:8080` — all
    /// the same. Without this normalization the first request fails, and
    /// the message reads "unreachable" although the address is correct.
    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Without a scheme `URL` takes the text as a path instead of as a host name. Since
        // such providers almost never work with a certificate, HTTP is the
        // right assumption — HTTPS would fail with most.
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }

        // A trailing slash doubles later when assembling
        // to `//player_api.php`, which some servers reject.
        while text.hasSuffix("/") {
            text.removeLast()
        }

        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    /// The account as a key — **without password.**
    ///
    /// What for: The ``ConnectionLock`` queues requests per account at the provider,
    /// and an account is host **and** username. Two lists on the same
    /// host with different users are two accounts with one
    /// connection each; two ``XtreamClient`` instances on the same user are one.
    ///
    /// **The password is deliberately not in it.** The key travels into
    /// log lines as soon as someone wants to trace the queue — and for
    /// everything that contains an address, ``redacted(_:)`` applies here.
    public var accountIdentifier: String { "\(server.absoluteString)|\(username)" }

    // MARK: - Adressen

    /// The address for a query of the interface.
    ///
    /// Username and password are **encoded**: Both may contain characters
    /// that have a meaning in an address — an `&` in the password
    /// would otherwise cut the query in the middle, and the account would seem wrong.
    public func apiURL(action: String, extra: [String: String] = [:]) -> URL? {
        var components = URLComponents(
            url: server.appendingPathComponent("player_api.php"),
            resolvingAgainstBaseURL: false
        )
        var items = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
        ]
        if !action.isEmpty {
            items.append(URLQueryItem(name: "action", value: action))
        }
        items += extra.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }

        components?.queryItems = items
        return components?.url
    }

    /// The complete channel list of the account in M3U format.
    ///
    /// **Deliberately `type=m3u` and not `m3u_plus`:** The slim version
    /// weighs 11 MB instead of 30 and carries both things that matter — the name
    /// after the comma and the address. The extras of `m3u_plus`
    /// (logo, group, `tvg-id`) cost only bytes here.
    ///
    /// **Caution with this path.** With the checked provider `get.php` was blocked well into
    /// August — 26 variants ran into the status code
    /// `884` — and has answered again since 2026-08-22. Whether that lasts, nobody
    /// knows. Build nothing on it that stops working without it.
    public var playlistURL: URL? {
        var components = URLComponents(
            url: server.appendingPathComponent("get.php"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "type", value: "m3u"),
            URLQueryItem(name: "output", value: "ts"),
        ]
        return components?.url
    }

    /// The complete program guide of the account.
    ///
    /// **One fetch for everything**, as opposed to `get_short_epg`, which asks per channel.
    /// With the checked provider that is 75 MiB for 610 of 5389 channels
    /// — too much for memory, but just right for the cache:
    /// Fetched once, every program afterwards comes from disk instead of the
    /// network (roadmap P8.2).
    public var guideURL: URL? {
        var components = URLComponents(
            url: server.appendingPathComponent("xmltv.php"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
        ]
        return components?.url
    }

    /// The address of a live channel.
    ///
    /// The structure is fixed by the Xtream protocol and cannot be queried — it
    /// is assembled: `/live/USER/PASSWORD/ID.ts`
    public func liveStreamURL(streamID: Int, extension fileExtension: String = "ts") -> URL? {
        streamURL(section: "live", id: streamID, extension: fileExtension)
    }

    /// The address of a **catch-up** — a program that has already aired.
    ///
    /// **51 of 5389 channels of this provider offer three days of archive**
    /// (`design/konzept-p8.md`, section 4); whether a channel can do it is stated as
    /// `tv_archive` in its entry and has been in ``Channel/archiveDays`` since E6.
    ///
    /// The structure is fixed as with the live channel and cannot be queried:
    /// `/timeshift/USER/PASSWORD/DURATION/START/ID.m3u8`. The duration counts
    /// **minutes**, the start is in the provider format `YYYY-MM-DD:HH-MM` — with
    /// a colon between day and hour and a hyphen between hour and
    /// minute, which matches no common pattern and is therefore built
    /// by hand here.
    ///
    /// **In the provider's time zone, not the device's.** The server
    /// evaluates the value against its own clock; whoever takes the local one fetches the
    /// program before with one hour of difference. The default is therefore GMT —
    /// the same basis on which the program times in the cache lie.
    ///
    /// - Returns: `nil` if the duration is not one — a recording of
    ///   zero minutes would be an address the server can only reject.
    public func timeshiftURL(
        streamID: Int,
        start: Date,
        minutes: Int,
        timeZone: TimeZone = TimeZone(identifier: "GMT") ?? .gmt
    ) -> URL? {
        guard minutes > 0 else { return nil }
        var text = server.absoluteString
        text += "/timeshift/\(username)/\(password)/\(minutes)/"
        text += "\(Catchup.stamp(start, in: timeZone))/\(streamID).m3u8"
        return URL(string: text)
    }

    private func streamURL(section: String, id: Int, extension fileExtension: String) -> URL? {
        // The extension may be empty if the provider names none. Then
        // it is left out instead of leaving a dot at the end.
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"

        // Here **not** via `URLComponents`: Username and password are
        // path components, not query values. An encoded slash in the
        // password would become `%2F` and the server would not find the path.
        var text = server.absoluteString
        text += "/\(section)/\(username)/\(password)/\(id)\(suffix)"
        return URL(string: text)
    }

    // MARK: - Schutz in Meldungen

    /// Replaces the password in a text with a placeholder.
    ///
    /// Applied to **every** string that can contain an address,
    /// before it goes into a message or a log. A log travels into
    /// error reports — a password in it would be given away.
    public func redacted(_ text: String) -> String {
        guard !password.isEmpty else { return text }
        return text.replacingOccurrences(of: password, with: "•••")
    }
}
