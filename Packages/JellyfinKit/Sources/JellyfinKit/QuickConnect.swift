import Core
import Foundation

/// Signing in without typing a password on the TV.
///
/// The flow is Jellyfin's own and needs no extra software: the TV requests a six-digit
/// code and displays it. Whoever is already signed in on a phone or computer enters the
/// code there and confirms. Meanwhile the TV polls at intervals and gets its access
/// token as soon as confirmation has happened.
///
/// This is the more pleasant way: typing a password with the remote on an on-screen
/// keyboard is tedious and error-prone — especially for characters reached by switching
/// layouts.
public actor QuickConnect {

    public enum Failure: Error, Equatable {
        /// The server has turned the feature off.
        case notEnabled
        /// The code expired before anyone confirmed it.
        case expired
        case unreachable

        public var messageKey: String {
            switch self {
            case .notEnabled: "error.quickConnectDisabled"
            case .expired: "error.quickConnectExpired"
            case .unreachable: "error.unreachable"
            }
        }
    }

    /// What the TV shows while it waits.
    public struct Session: Sendable, Equatable {
        /// The six-digit code for display.
        public let code: String
        /// Is sent along when polling and must not be displayed.
        let secret: String

        /// A code without a secret — **for tests only**, which want to enter in the middle of the
        /// code step without asking a server.
        @_spi(Check) public static let forCheck = Session(code: "000000", secret: "")

        /// The code in groups of two — from a distance considerably easier to read off and type
        /// than six digits in a row.
        public var groupedCode: String {
            stride(from: 0, to: code.count, by: 2)
                .map { offset -> String in
                    let start = code.index(code.startIndex, offsetBy: offset)
                    let end = code.index(start, offsetBy: min(2, code.count - offset))
                    return String(code[start..<end])
                }
                .joined(separator: " ")
        }
    }

    nonisolated let session: URLSession
    private let decoder = JellyfinDecoder.make()

    /// - Parameter protokolle: For tests only — a `URLProtocol` class that supplies the
    ///   server's responses. **A parameter and no global
    ///   `URLProtocol.registerClass`**, because the session here is `ephemeral`: the global
    ///   registration does not take effect there, and a check that turns green anyway has in
    ///   truth asked nothing at all.
    ///
    /// **With the same certificate trust as sign-in** (setup check, E10, 2026-09-27). Until
    /// then without ``TrustingSessionDelegate``: with a confirmed, self-issued certificate
    /// the address check succeeded, and `isEnabled` failed on TLS — the code button was
    /// missing, and the phone could not confirm a TV code.
    public init(
        timeout: TimeInterval = 25, protocols: [AnyClass] = [],
        trustStore: CertificateTrustStore = CertificateTrustStore()
    ) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        if !protocols.isEmpty { config.protocolClasses = protocols }
        self.session = URLSession(
            configuration: config, delegate: TrustingSessionDelegate(trustStore: trustStore),
            delegateQueue: nil)
    }

    /// Whether the server offers the feature at all. If it is off, sign-in with a password
    /// must be offered — that is why this is checked up front and not only once the user has
    /// already chosen the path.
    public func isEnabled(server: URL) async -> Bool {
        guard
            let (data, response) = try? await session.data(
                from: server.appending(path: "QuickConnect/Enabled")),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let text = String(data: data, encoding: .utf8)
        else { return false }

        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    public func begin(server: URL, deviceID: String, deviceName: String) async throws -> Session {
        var request = URLRequest(url: server.appending(path: "QuickConnect/Initiate"))
        // **POST and not GET** (on-device test 2026-09-27): Jellyfin 12 answers a GET with 405,
        // and that read here like "Quick Connect turned off".
        request.httpMethod = "POST"
        request.setValue(
            JellyfinConnection.authorizationHeader(deviceID: deviceID, deviceName: deviceName),
            forHTTPHeaderField: "Authorization"
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
            guard http.statusCode == 200 else { throw Failure.notEnabled }

            let result = try decoder.decode(InitiateResponse.self, from: data)
            return Session(code: result.code, secret: result.secret)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreachable
        }
    }

    /// Waits until sign-in has been confirmed on the other device.
    ///
    /// - Parameter interval: Gap between polls. Five seconds is a middle path — more often
    ///   burdens the server without noticeable gain, less often feels sluggish.
    public func waitForApproval(
        server: URL,
        session quickConnect: Session,
        deviceID: String,
        deviceName: String,
        interval: Duration = .seconds(5),
        timeout: Duration = .seconds(300)
    ) async throws -> ServerCredentials {
        let deadline = ContinuousClock.now.advanced(by: timeout)

        // Over a shaky connection a single poll fails again and again. That must not end the
        // sign-in — as long as there is time, it is retried. Only several failures in a row
        // count as actually unreachable.
        var consecutiveFailures = 0
        let tolerated = 4

        while ContinuousClock.now < deadline {
            do {
                if try await isApproved(server: server, secret: quickConnect.secret) {
                    return try await redeem(
                        server: server,
                        secret: quickConnect.secret,
                        deviceID: deviceID,
                        deviceName: deviceName
                    )
                }
                consecutiveFailures = 0
            } catch Failure.expired {
                // The server no longer knows the code — further waiting would be futile.
                throw Failure.expired
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures > tolerated { throw Failure.unreachable }
            }
            try await Task.sleep(for: interval)
        }
        throw Failure.expired
    }

    func isApproved(server: URL, secret: String) async throws -> Bool {
        var components = URLComponents(
            url: server.appending(path: "QuickConnect/Connect"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "secret", value: secret)]
        guard let url = components?.url else { throw Failure.unreachable }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
            // The server discards expired codes and then answers with 404.
            guard http.statusCode != 404 else { throw Failure.expired }
            guard http.statusCode == 200 else { throw Failure.unreachable }

            return try decoder.decode(ConnectResponse.self, from: data).authenticated
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreachable
        }
    }

    /// Redeems the confirmed request for an access token.
    ///
    /// Tried several times, and for good reason: over an unsteady line the data packet sent
    /// sometimes arrives incomplete — the server then reports `Unexpected end of request
    /// content`. A single attempt would let the entire sign-in fail at this last point,
    /// although the confirmation has long since happened.
    func redeem(
        server: URL,
        secret: String,
        deviceID: String,
        deviceName: String,
        attempts: Int = 3
    ) async throws -> ServerCredentials {
        var lastFailure: Error?

        for attempt in 1...attempts {
            do {
                return try await redeemOnce(
                    server: server,
                    secret: secret,
                    deviceID: deviceID,
                    deviceName: deviceName
                )
            } catch {
                // bewusst still: the last error is thrown after the last attempt; whoever catches
                // it records it.
                lastFailure = error
                if attempt < attempts {
                    // Let it catch its breath briefly; a disturbed connection usually recovers within
                    // fractions of a second.
                    try? await Task.sleep(for: .milliseconds(700))
                }
            }
        }
        throw lastFailure ?? Failure.expired
    }

    // MARK: - The other side: authorize

    /// Confirms a code that **another** device displays.
    ///
    /// **The counterpart to ``begin(server:deviceID:deviceName:)``** — and the half that was
    /// missing until 2026-09-21. The TV requests a code and waits; so far confirmation
    /// happened on the phone **in Jellyfin's own web interface**. That means: whoever has
    /// CineLounge on the phone still had to open the browser.
    ///
    /// **And it is the way that resolves AP43's token question.** Whether a Jellyfin token
    /// is valid on a second device is something nobody has to answer: the second device gets
    /// its **own**, and this one waves it through. No password travels anywhere in the
    /// process — neither over the network nor through CloudKit.
    ///
    /// - Parameters:
    ///   - code: the six digits the other device shows.
    ///   - token: the access token of **this** device. Without a signed-in session there is
    ///     nothing to confirm — that is why it is not a choice but required.
    /// - Returns: `true` if the server accepted the confirmation.
    /// - Throws: ``Failure/expired`` if the code is not (or no longer) valid —
    ///   ``Failure/notEnabled`` if the server has the feature off.
    @discardableResult
    public func authorize(
        server: URL, code: String, token: String, deviceID: String, deviceName: String
    ) async throws -> Bool {
        // **The code goes in the query and not in the body.** Jellyfin expects it exactly that
        // way (`POST /QuickConnect/Authorize?code=…`); a JSON body is silently ignored, and the
        // response is then "false" without an error.
        var split = URLComponents(
            url: server.appending(path: "QuickConnect/Authorize"), resolvingAgainstBaseURL: false)
        split?.queryItems = [URLQueryItem(name: "code", value: code)]
        guard let target = split?.url else { throw Failure.unreachable }

        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.setValue(
            JellyfinConnection.authorizationHeader(
                deviceID: deviceID, deviceName: deviceName, token: token),
            forHTTPHeaderField: "Authorization"
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        switch http.statusCode {
        case 200:
            // **The server answers with `true` or `false`, both with 200.** `false` means "this code
            // does not exist (any more)" — whoever looks only at the status code reports success
            // and leaves the other screen waiting forever.
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard text == "true" else { throw Failure.expired }
            return true
        case 403, 404:
            // 403: the server does not allow it. 404: the feature is off, so the path does not exist
            // at all.
            throw Failure.notEnabled
        case 400, 401:
            throw Failure.expired
        default:
            throw Failure.unreachable
        }
    }

    private func redeemOnce(
        server: URL,
        secret: String,
        deviceID: String,
        deviceName: String
    ) async throws -> ServerCredentials {
        var request = URLRequest(url: server.appending(path: "Users/AuthenticateWithQuickConnect"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            JellyfinConnection.authorizationHeader(deviceID: deviceID, deviceName: deviceName),
            forHTTPHeaderField: "Authorization"
        )

        let body = try JSONEncoder().encode(["Secret": secret])
        request.httpBody = body
        // Pass it explicitly: without the length the system transfers in chunks, and an abort
        // midway leaves the server with half a data packet.
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        guard http.statusCode == 200 else {
            // 400 and 401 mean here: the request is no longer valid. Everything else is more a
            // connection disturbance and worth another attempt.
            throw http.statusCode == 400 || http.statusCode == 401
                ? Failure.expired : Failure.unreachable
        }

        let result = try decoder.decode(JellyfinConnection.AuthenticationResult.self, from: data)
        return ServerCredentials(
            serverURL: server,
            userID: result.user.id,
            username: result.user.name,
            accessToken: result.accessToken,
            serverID: result.serverID
        )
    }

    // MARK: - Antworten

    struct InitiateResponse: Decodable {
        let code: String
        let secret: String

        enum CodingKeys: String, CodingKey {
            case code = "Code"
            case secret = "Secret"
        }
    }

    struct ConnectResponse: Decodable {
        let authenticated: Bool

        enum CodingKeys: String, CodingKey {
            case authenticated = "Authenticated"
        }
    }
}
