import Foundation

/// What the TV and the phone store in the Keychain — Jellyfin accesses, the account list
/// and the keys of the rating services.
///
/// **The cut** (Grundstock, 2026-09-17): ``SecureStore`` itself — `set`, `value`, `remove`,
/// `contains` — lives in the base and knows nothing of a media server. What is here knows
/// the access token, user identifier and server identifier of a Jellyfin and therefore
/// belongs to `Core`. The reading app stores its accounts with the same four basic verbs,
/// only under different keys.
/// What remains of a sign-in and has to survive a restart.
///
/// The password is deliberately **not** in it: At sign-in the server issues an access
/// token, and only that is kept. That way a stolen device can be locked out on the server
/// side without the password being known.
public struct ServerCredentials: Sendable, Equatable, Codable {
    public let serverURL: URL
    public let userID: String
    public let username: String
    public let accessToken: String

    /// Who the server is — **regardless of where it stands.**
    ///
    /// Jellyfin reports it as `Id` in `System/Info/Public` and in the sign-in result, and it is
    /// the only information by which a **move** can be told apart from a **second server**:
    /// Whoever moves still has one server, with the same account, the same progress and the
    /// same favorites; whoever adds a second has two. Without this identifier the move would be
    /// a button that guesses — and a wrongly guessed one lays two catalogs on top of each other.
    ///
    /// **Optional, and that is no convenience.** Accesses that went into the Keychain before
    /// this line do not carry it; a non-optional field would make them fail on reading and tell
    /// every existing user they are signed out. It fills itself at the next sign-in.
    public let serverID: String?

    public init(
        serverURL: URL, userID: String, username: String, accessToken: String,
        serverID: String? = nil
    ) {
        self.serverURL = serverURL
        self.userID = userID
        self.username = username
        self.accessToken = accessToken
        self.serverID = serverID
    }

    /// The same access under a new address — **for the move and only for that.**
    public func under(address: URL) -> ServerCredentials {
        ServerCredentials(
            serverURL: address, userID: userID, username: username,
            accessToken: accessToken, serverID: serverID)
    }
}

extension SecureStore {

    private static let credentialsKey = "server.credentials"

    public func saveCredentials(_ credentials: ServerCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        guard let json = String(data: data, encoding: .utf8) else { throw Failure.malformed }
        try set(json, for: Self.credentialsKey)
    }

    public func loadCredentials() throws -> ServerCredentials {
        let json = try value(for: Self.credentialsKey)
        guard let data = json.data(using: .utf8) else { throw Failure.malformed }
        return try JSONDecoder().decode(ServerCredentials.self, from: data)
    }

    public func clearCredentials() throws {
        try remove(Self.credentialsKey)
    }
}

extension SecureStore {

    private static let accountsKey = "server.accounts"

    /// **Several sessions per server instead of one overall.**
    ///
    /// Until 2026-09-06 the Keychain held exactly one sign-in. An account switch therefore went
    /// through **sign out** — and signing out takes along more than the name says: snapshots
    /// per library, the Top Shelf marker and the image store. Whoever switches between two
    /// accounts on the TV pays each time with an app that has to refill itself.
    ///
    /// **Built additively, and that is half the decision.** ``loadCredentials()`` and
    /// ``saveCredentials(_:)`` remain what they were: the **signed-in** session. The list sits
    /// beside it. Thus nothing changes for everything that reads today — and the TV app, which
    /// stands on this file, does not have to be touched in order to keep running.
    ///
    /// An account stands in the list under **server and user identifier**: The same person on
    /// two servers is two accounts, two people on one server as well.
    public func allAccounts() -> [ServerCredentials] {
        guard let json = try? value(for: Self.accountsKey),
            let data = json.data(using: .utf8),
            let list = try? JSONDecoder().decode([ServerCredentials].self, from: data)
        else { return [] }
        return list
    }

    /// Adds an access to the list — **and replaces what belongs to the same account.**
    ///
    /// A second sign-in of the same person on the same server is not a second account but a
    /// fresher access token. Making two entries of it would mean keeping an expired token and
    /// using it at the next switch.
    public func memorize(_ credential: ServerCredentials) throws {
        var list = allAccounts().filter {
            !($0.serverURL == credential.serverURL && $0.userID == credential.userID)
        }
        list.append(credential)
        let data = try JSONEncoder().encode(list)
        guard let json = String(data: data, encoding: .utf8) else { throw Failure.malformed }
        try set(json, for: Self.accountsKey)
    }

    /// Rewrites the address of a server — **in the list and in the session.**
    ///
    /// **A move is not a sign-in.** The access token stays valid; it belongs to the server and
    /// not to its address. Whoever solves the move through sign out and sign in again takes
    /// snapshots, image store and markers with it — exactly what the account list is meant to
    /// avoid.
    ///
    /// **What is compared here is the address and not the identifier.** Whether it is the same
    /// server at all is decided beforehand by the comparison via ``ServerCredentials/serverID``;
    /// here only the rewriting remains, and of everything that lies under the old address: A
    /// server that moves takes its accounts with it.
    ///
    /// **The session moves even without a list entry** (setup check, E4, 2026-09-27). A device
    /// from the time before the account list has a session and an empty list — per
    /// ``ProfileKit/Zugangsliste`` the normal case. Until then this method ended there with zero,
    /// the session kept pointing at the old address, and the move reported "moved" anyway. A
    /// session without its own entry counts too.
    ///
    /// - Returns: how many accesses were rewritten — **zero means: nothing stood under the old
    ///   address.**
    @discardableResult
    public func relocate(from old: URL, after fresh: URL) throws -> Int {
        let list = allAccounts()
        let relocated = list.map { $0.serverURL == old ? $0.under(address: fresh) : $0 }
        var count = zip(list, relocated).filter { $0 != $1 }.count
        if count > 0 {
            let data = try JSONEncoder().encode(relocated)
            guard let json = String(data: data, encoding: .utf8) else { throw Failure.malformed }
            try set(json, for: Self.accountsKey)
        }

        // The signed-in session stands beside it and has to come along — otherwise the app points
        // to an address that no longer exists while the list has long since moved.
        if let session = try? loadCredentials(), session.serverURL == old {
            try saveCredentials(session.under(address: fresh))
            if !list.contains(where: { $0.serverURL == old && $0.userID == session.userID }) {
                count += 1
            }
        }
        return count
    }

    /// Removes an access from the list.
    ///
    /// **Without touching the image store.** That is the whole purpose of this list: A removed
    /// account is one entry fewer and no cleanup.
    public func forget(server: URL, user: String) throws {
        let list = allAccounts().filter {
            !($0.serverURL == server && $0.userID == user)
        }
        let data = try JSONEncoder().encode(list)
        guard let json = String(data: data, encoding: .utf8) else { throw Failure.malformed }
        try set(json, for: Self.accountsKey)
    }

    /// Switches to an account that is already in the list.
    ///
    /// **No sign out, no sign in.** The access token is already there; the switch is an
    /// assignment and not a process that can fail — precisely for that reason the image store
    /// stays in place.
    public func switchTo(server: URL, user: String) throws {
        guard
            let found = allAccounts().first(where: {
                $0.serverURL == server && $0.userID == user
            })
        else { throw Failure.notFound }
        try saveCredentials(found)
    }
}

extension SecureStore {

    private static let omdbKeyName = "omdb.apikey"

    /// The personal access to the rating service.
    ///
    /// In the Keychain and not in the source: It belongs to the user, has a daily quota and
    /// would be readable in a checked-in file by anyone who gets hold of the project.
    public func omdbAPIKey() -> String? {
        try? value(for: Self.omdbKeyName)
    }

    private static let malKeyName = "mal.clientid"

    /// The client ID for MyAnimeList (AP68) — like the OMDb key a personal access that the user
    /// creates at myanimelist.net/apiconfig.
    public func malClientID() -> String? {
        try? value(for: Self.malKeyName)
    }

    public func setMALClientID(_ id: String) throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try remove(Self.malKeyName)
        } else {
            try set(trimmed, for: Self.malKeyName)
        }
    }

    public func setOMDbAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try remove(Self.omdbKeyName)
        } else {
            try set(trimmed, for: Self.omdbKeyName)
        }
    }

    private static let tmdbKeyName = "tmdb.apikey"

    /// The personal access to the film database — for a person's career.
    ///
    /// A **second** key next to the one for the ratings, and that is no oversight: They are two
    /// different services with separate accounts. Keeping them in one field would mean that a
    /// mistyped entry switches off both displays at once and nobody can say which of the two
    /// was meant.
    public func tmdbAPIKey() -> String? {
        try? value(for: Self.tmdbKeyName)
    }

    public func setTMDbAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try remove(Self.tmdbKeyName)
        } else {
            try set(trimmed, for: Self.tmdbKeyName)
        }
    }
}
