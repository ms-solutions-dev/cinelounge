import Core
import Foundation

/// Connection to a Jellyfin server: check reachability, sign in, sign out.
///
/// Deliberately built without the generated SDK. For the three calls at issue here,
/// its setup would be more detour than help — and the error messages
/// should be precise enough that the TV says *what* is wrong, instead of
/// "Sign-in failed".
public actor JellyfinConnection {

    public enum Failure: Error, Equatable {
        /// The address does not yield a valid server.
        case invalidAddress
        /// Nothing answered — wrong address, server off, or not on the network.
        case unreachable
        /// Answered, but it is not Jellyfin.
        case notAJellyfinServer
        case wrongCredentials
        case timedOut
        case server(status: Int)
        /// The certificate is self-issued and not yet confirmed.
        /// The UI shows the fingerprint and asks.
        case certificateNeedsConfirmation

        /// Translation key for display. The message itself does not belong
        /// here — it depends on the device's language.
        public var messageKey: String {
            switch self {
            case .invalidAddress: "error.invalidAddress"
            case .unreachable: "error.unreachable"
            case .notAJellyfinServer: "error.notAJellyfinServer"
            case .wrongCredentials: "error.wrongCredentials"
            case .timedOut: "error.timedOut"
            case .server: "error.server"
            case .certificateNeedsConfirmation: "error.certificateUnknown"
            }
        }
    }

    /// What the server reveals about itself before you are signed in.
    public struct ServerInfo: Sendable, Equatable, Decodable {
        public let serverName: String
        public let version: String
        public let id: String

        public init(serverName: String, version: String, id: String) {
            self.serverName = serverName
            self.version = version
            self.id = id
        }

        enum CodingKeys: String, CodingKey {
            case serverName = "ServerName"
            case version = "Version"
            case id = "Id"
        }
    }

    private let session: URLSession
    private let decoder = JellyfinDecoder.make()

    public init(timeout: TimeInterval = 25, trustStore: CertificateTrustStore = CertificateTrustStore()) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        // On a TV a hanging sign-in is worse than a quick error message —
        // the user has no way to cancel other than quitting the app.
        config.waitsForConnectivity = false
        // Allows self-issued certificates, but only those whose
        // fingerprint the user has confirmed once.
        self.session = URLSession(
            configuration: config,
            delegate: TrustingSessionDelegate(trustStore: trustStore),
            delegateQueue: nil
        )
    }

    /// Completes missing parts of a typed address.
    ///
    /// Nobody likes typing `http://` on a TV — the input should work anyway.
    public nonisolated static func normalizeAddress(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if !text.contains("://") {
            text = "http://" + text
        }
        guard var components = URLComponents(string: text), components.host?.isEmpty == false else {
            return nil
        }
        // A trailing slash would otherwise double with every call.
        components.path =
            components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        return components.url
    }

    /// The addresses that are tried in order for one input.
    ///
    /// Necessary because an input like `jellyfin.example` is ambiguous: Behind it
    /// often sits an upstream proxy on port 80 that redirects to
    /// encrypted connections — and no Apple device trusts their self-issued
    /// certificates. The server itself then listens on its own port. Instead of
    /// letting the user guess, the app tries the usual variants in turn.
    ///
    /// **Since 2026-09-07 also encrypted (G2).** Until then exactly two addresses arose from
    /// one input, and both were `http` —
    /// ``normalizeAddress(_:)`` always prepends `http://` to an input without a scheme.
    /// A server that answers **only** over TLS was thus unreachable from a
    /// typed short form; precisely the case for which ``CertificateTrustStore`` and the
    /// certificate question were built in the first place.
    ///
    /// **The order is half the decision, and it follows the input:**
    ///
    /// - **A stated port is a statement.** Whoever types `:8096` knows where
    ///   they want to go; turning that into a list would override their statement.
    /// - **An explicit `https` is never rolled back to `http`.** The old version
    ///   did that: It appended `http://host:8096` to every input without a port, even to one
    ///   that began with `https://`. A connection the user requested encrypted must not
    ///   come about unnoticed in plain text.
    /// - **Otherwise plaintext first.** In the home network — this project's normal
    ///   case — the server answers unencrypted. A TLS attempt placed first cost a timeout at every start, even
    ///   where it never finds anything.
    ///
    /// **The price is in the timeout.** Two addresses have become four,
    /// and ``probe(_:)`` waits per address up to the session's time limit. The
    /// worst case is thus twice as long as before. It only occurs
    /// when a machine **accepts the connection and then stays silent** — a name
    /// that does not resolve fails immediately. How long this sum actually
    /// becomes on the TV is not yet known by measurement and is a separate
    /// item in G2.
    public nonisolated static func candidates(for url: URL) -> [URL] {
        guard url.port == nil,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return [url] }

        func variant(_ schema: String, _ port: Int?) -> URL? {
            components.scheme = schema
            components.port = port
            return components.url
        }

        // Jellyfin's own ports: 8096 in plaintext, 8920 encrypted.
        if url.scheme == "https" {
            return [url] + [variant("https", 8920)].compactMap { $0 }
        }
        return [url]
            + [
                variant("http", 8096),
                variant("https", nil),
                variant("https", 8920),
            ].compactMap { $0 }
    }

    /// Tries the variants in turn and returns the first one that answers.
    public func probeAny(_ url: URL) async throws -> (url: URL, info: ServerInfo) {
        var lastFailure: Failure = .unreachable
        let candidates = Self.candidates(for: url)

        Diagnostics.network.info(
            // **Masked and not raw** (AP50, 2026-09-23). It is the own
            // media server and no provider access — still the same design:
            // ``Grundstock/Diagnostics/loggable(_:)`` removes query, token, user
            // and password. `http://user:secret@server/` occurs, and
            // a trace that can be submitted must not carry that.
            "Address \(Diagnostics.loggable(url), privacy: .public): \(candidates.count) variants"
        )

        for candidate in candidates {
            Diagnostics.attempt(candidate, step: "Check server")
            do {
                let info = try await probe(candidate)
                Diagnostics.success(
                    candidate, step: "Check server", detail: "\(info.serverName) \(info.version)")
                return (candidate, info)
            } catch let failure as Failure {
                Diagnostics.network.error(
                    "✗ Check server: \(Diagnostics.loggable(candidate), privacy: .public) — \(failure.messageKey, privacy: .public)"
                )
                lastFailure = failure
            } catch {
                Diagnostics.failure(candidate, step: "Check server", error: error)
                lastFailure = .unreachable
            }
        }
        throw lastFailure
    }

    /// Checks whether a Jellyfin actually answers at the address.
    public func probe(_ url: URL) async throws -> ServerInfo {
        let endpoint = url.appending(path: "System/Info/Public")

        do {
            let (data, response) = try await session.data(from: endpoint)
            guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
            guard http.statusCode == 200 else { throw Failure.server(status: http.statusCode) }

            do {
                return try decoder.decode(ServerInfo.self, from: data)
            } catch {
                // Something answered, but it does not speak Jellyfin —
                // typically a router or another service on the same port.
                throw Failure.notAJellyfinServer
            }
        } catch let failure as Failure {
            throw failure
        } catch let error as URLError where error.code == .timedOut {
            Diagnostics.failure(endpoint, step: "Check server", error: error)
            throw Failure.timedOut
        } catch let error as URLError where Self.isCertificateProblem(error) {
            // Not a network error but a question of trust — the
            // UI can offer the fingerprint for confirmation.
            Diagnostics.failure(endpoint, step: "Check server", error: error)
            throw Failure.certificateNeedsConfirmation
        } catch {
            // The actual cause is here — afterwards it is generalized into a
            // coarse error case and can no longer be found.
            Diagnostics.failure(endpoint, step: "Check server", error: error)
            throw Failure.unreachable
        }
    }

    /// Whether an error stems from the certificate not being trusted.
    static func isCertificateProblem(_ error: URLError) -> Bool {
        [
            .secureConnectionFailed, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
            .serverCertificateNotYetValid, .cancelled,
        ].contains(error.code)
    }

    /// Signs in and returns the access token that is used from now on instead of the
    /// password.
    public func authenticate(
        server: URL,
        username: String,
        password: String,
        deviceID: String,
        deviceName: String
    ) async throws -> ServerCredentials {
        var request = URLRequest(url: server.appending(path: "Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            Self.authorizationHeader(deviceID: deviceID, deviceName: deviceName),
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(
            ["Username": username, "Pw": password]
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }

            switch http.statusCode {
            case 200:
                let result = try decoder.decode(AuthenticationResult.self, from: data)
                return ServerCredentials(
                    serverURL: server,
                    userID: result.user.id,
                    username: result.user.name,
                    accessToken: result.accessToken,
                    serverID: result.serverID
                )
            case 401:
                throw Failure.wrongCredentials
            default:
                throw Failure.server(status: http.statusCode)
            }
        } catch let failure as Failure {
            throw failure
        } catch let error as URLError where error.code == .timedOut {
            throw Failure.timedOut
        } catch is DecodingError {
            throw Failure.notAJellyfinServer
        } catch {
            throw Failure.unreachable
        }
    }

    /// Signs the access token out at the server so that it becomes invalid there.
    ///
    /// Called by `Flows/SignOut` — on both devices, hence the device name as
    /// a parameter; the server recognizes the device by its identifier.
    public func logout(
        credentials: ServerCredentials, deviceID: String, deviceName: String = JellyfinConnection.deviceKind
    ) async {
        var request = URLRequest(url: credentials.serverURL.appending(path: "Sessions/Logout"))
        request.httpMethod = "POST"
        request.setValue(
            Self.authorizationHeader(
                deviceID: deviceID,
                deviceName: deviceName,
                token: credentials.accessToken
            ),
            forHTTPHeaderField: "Authorization"
        )
        // A failure is acceptable: Locally the sign-in is gone anyway.
        _ = try? await session.data(for: request)
    }

    /// The app's version, as the build records it.
    ///
    /// From the bundle instead of hardcoded: The number appears in the server's device list
    /// and in the name of every uploaded log — a hard-coded "0.1.0" would have
    /// concealed every later version there, and nobody would have noticed, because the number
    /// looks plausible. The fallback carries the tests: Under SwiftPM there is no app bundle.
    nonisolated static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.1.0"
    }

    /// The header entry by which Jellyfin recognizes the device. It appears in
    /// the server's device list — hence a descriptive name.
    /// What this device calls itself at Jellyfin — **by platform.**
    ///
    /// **The finding (2026-09-28):** This used to be a fixed "Apple TV", even in the phone app.
    /// A playback on the iPhone appeared in the Jellyfin log as "on Apple TV", and
    /// the troubleshooting went in the wrong direction. The device type is enough — the identifier separates
    /// the devices anyway.
    public nonisolated static var deviceKind: String {
        #if os(tvOS)
            "Apple TV"
        #elseif os(iOS)
            "iPhone"
        #else
            "Apple TV"
        #endif
    }

    nonisolated static func authorizationHeader(
        deviceID: String,
        deviceName: String,
        token: String? = nil
    ) -> String {
        var parts = [
            #"MediaBrowser Client="CineLounge""#,
            #"Device="\#(deviceName)""#,
            #"DeviceId="\#(deviceID)""#,
            #"Version="\#(appVersion)""#,
        ]
        if let token {
            parts.append(#"Token="\#(token)""#)
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Antworten

    struct AuthenticationResult: Decodable {
        let user: User
        let accessToken: String
        /// **Optional.** Jellyfin has reported it along for a long time, but an intermediate server or
        /// an older version may not — and a missing identifier must not
        /// make a sign-in fail. It is then simply missing, and the migration says so.
        let serverID: String?

        enum CodingKeys: String, CodingKey {
            case user = "User"
            case accessToken = "AccessToken"
            case serverID = "ServerId"
        }

        struct User: Decodable {
            let id: String
            let name: String

            enum CodingKeys: String, CodingKey {
                case id = "Id"
                case name = "Name"
            }
        }
    }
}
