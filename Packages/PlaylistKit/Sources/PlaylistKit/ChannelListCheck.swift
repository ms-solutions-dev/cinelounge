import Core
import Foundation

/// Whether an entered channel list still works — **and how a typed address
/// is read** (AP58 R7, finding E3).
///
/// **The finding:** The interpretation of the provider's response lived on the TV in
/// `PlaylistSettings.check` and on the phone in `ChannelListsView.interpret`, with their own
/// keys and a gap that both shared: `XtreamClient.verify()` throws on a
/// rejected or expired account, and both sides caught that as "does not respond".
/// "Rejected" and "expired" never arrived that way. The TV read the address
/// with scheme completion and host check, the phone with a bare `URL(string:)` — whoever entered
/// `provider.tv:8080` there got a list with the scheme `provider.tv`.
///
/// **The sentences stay per device**, the rule lives here: each side maps the ``Finding``
/// to its own row.
public enum ChannelListCheck {

    /// What the provider said about an account.
    public enum Finding: Sendable, Equatable {
        /// There is no password for the account — nobody asked.
        case withoutPassword
        /// Wrong user or wrong password.
        case rejected
        /// The account was once valid and no longer is (expired, blocked).
        case expired
        /// No usable response.
        case muted
        case isValid(StateInfo)
    }

    /// The numbers of a valid account — **the ones that decide something.**
    public struct StateInfo: Sendable, Equatable {
        /// The status verbatim, as the provider writes it ("Active").
        public let status: String?
        public let until: Date?
        public let taken: Int
        public let atMost: Int?
        /// Whether the account yields only raw streams (no HLS) — then the remuxer plays.
        public let rawOnly: Bool

        public init(status: String?, until: Date?, taken: Int, atMost: Int?, rawOnly: Bool) {
            self.status = status
            self.until = until
            self.taken = taken
            self.atMost = atMost
            self.rawOnly = rawOnly
        }
    }

    /// The provider's response as a finding — **three causes, three cases.**
    public static func interpret(_ reply: XtreamPayload.AccountInfo) -> Finding {
        guard reply.isAuthorized else { return .rejected }
        guard reply.isActive else { return .expired }
        return .isValid(
            StateInfo(
                status: reply.status, until: reply.expiryDate,
                taken: reply.activeConnections ?? 0, atMost: reply.maxConnections,
                rawOnly: !reply.allowsHLS))
    }

    /// A thrown error from `verify()` as a finding — **the gap both sides
    /// had:** `verify()` throws on `auth != 1` and on a status other than "Active".
    public static func interpret(_ error: any Error) -> Finding {
        switch error as? XtreamClient.Failure {
        case .unauthorized: .rejected
        case .accountDisabled: .expired
        default: .muted
        }
    }

    /// Asks a provider account **once** — one request to `player_api.php`, no
    /// stream connection. `nil` for a list without an inquiry path (M3U, media server): loading the
    /// whole file would be too expensive for one row in settings.
    public static func verify(_ list: Playlist, password: String?) async -> Finding? {
        guard case .xtream(let server, let user) = list.kind else { return nil }
        guard let password, !password.isEmpty else { return .withoutPassword }
        let credential = XtreamEndpoint(server: server, username: user, password: password)
        do {
            return interpret(try await XtreamClient(playlist: list, credentials: credential).verify())
        } catch {
            // **With the host of the list** (diagnosis F-025, 2026-09-28): three lists,
            // three times "unreachable", and no row said which.
            Diagnostics.defect(
                "Channel list \(server.host() ?? list.name) checked, without success: \(Diagnostics.explain(error))",
                since: nil, area: "Live")
            return interpret(error)
        }
    }

    /// A typed list or guide address (M3U, XMLTV) — **with scheme and with
    /// host**, otherwise `nil`.
    ///
    /// Without a scheme `URL` takes the text as a path or the first part before the colon as
    /// the scheme. `http://` is added: such addresses rarely carry a certificate. **The
    /// path stays as it is** — unlike with an Xtream server address
    /// (``XtreamEndpoint/normalize(_:)``), a trailing slash here is part
    /// of the file.
    public static func address(_ input: String) -> URL? {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let lowercased = clean.lowercased()
        let withScheme =
            lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") ? clean : "http://" + clean
        guard let url = URL(string: withScheme), url.host()?.isEmpty == false else { return nil }
        return url
    }

    /// The server address of an Xtream account — same rule as ``XtreamEndpoint``.
    public static func serverAddress(_ input: String) -> URL? {
        XtreamEndpoint.normalize(input)
    }
}
