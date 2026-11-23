import Core
import Foundation

/// The connection to the portal service — nine addresses, nothing else.
///
/// **The app knows no page, no pattern and no host.** It talks to a server on the home
/// network, and that knows what a portal is. That is not mere caution but the design:
/// how a portal reads its pages changes far more often than an app can be released — if
/// that were in here, every such change would be a new submission to the store. App Store
/// rule 2.5.2 moreover forbids downloaded executable code, and a portal script that updates
/// itself is exactly that.
///
/// **Two services, one connection (2026-09-12).** Up to here the service was the
/// portals bridge; now it is the CineLounge server, and for a while both exist. Which
/// one answers is told by ``ServerVersion/probe(_:session:)``, and the
/// ``PortalDialect`` translates paths, query parts and response keys — **here and only
/// here**. Everything above keeps speaking the bridge's language and notices nothing
/// of the difference.
///
/// Plain text over HTTP and without a certificate: both services sit on the own network
/// and listen only there. With the server the plain text on 8100 is moreover
/// intentional — a TV should not fail on a certificate chain that protects nothing on the
/// own network.
public struct PortalBridge: Sendable {

    public let basis: URL
    /// In which words this service speaks.
    public let dialect: PortalDialect
    /// The device token that is on **every** request — `nil` as long as not signed in, and
    /// always with the bridge.
    public let trait: String?
    /// The borrowed profile of a device without a person — **only on the TV.**
    public let profile: String?
    private let session: URLSession

    public init(
        basis: URL,
        dialect: PortalDialect = .bridge,
        trait: String? = nil,
        profile: String? = nil,
        session: URLSession = .shared
    ) {
        self.basis = basis
        self.dialect = dialect
        self.trait = trait
        self.profile = profile
        self.session = session
    }

    /// The same connection with a different token — after sign-in, profile switch or
    /// sign-out.
    ///
    /// **As a new connection and not as a mutable field:** a `PortalBridge` is `Sendable`
    /// and is passed across actor boundaries; a token that changes along the way would be
    /// set on one side and not on the other.
    public func using(trait: String?, profile: String? = nil) -> PortalBridge {
        PortalBridge(
            basis: basis, dialect: dialect, trait: trait, profile: profile,
            session: session)
    }

    // ── Fehler ───────────────────────────────────────────────────────────────

    /// Why something did not work — in plain text, not as a number.
    ///
    /// The bridge answers a failure with `{"detail": "…"}` and names in it the reason the
    /// portal gave. That belongs on the TV: "does not work" is not information, "setting
    /// required but empty" is.
    ///
    /// **The server answers differently, and that is progress:**
    /// `{"error":{"code":"stream.geo_blocked","values":{"country":"DE"}}}` — a code and its
    /// placeholders, never a finished sentence. The sentence is built by the app, in `de`,
    /// `en` or `tr`. Hence ``cancelled`` next to ``rejected``: a code the app can translate
    /// and a text it can only pass on are not the same, and a common case would have made
    /// the worse of both.
    public enum TestError: LocalizedError {
        case unreachable(underlying: Error)
        case rejected(status: Int, reason: String)
        /// The server refused with a code — `values` are the placeholders.
        case cancelled(status: Int, code: String, values: [String: String])
        case unreadable

        /// **A log text, not a screen text** (check 2026-09-27, design B2). What is displayed is
        /// ``message(lookUp:)`` via ``sentenceKey`` — also for ``unreachable`` and
        /// ``unreadable``, which carry keys of their own for it.
        public var errorDescription: String? {
            switch self {
            case .unreachable:
                "The portal service does not answer."
            case .rejected(_, let reason):
                reason
            case .cancelled(_, let code, _):
                // **The code and not an empty text.** A message without a translation should stand out
                // instead of silently vanishing; the UI replaces it with the sentence as soon as it has
                // one.
                code
            case .unreadable:
                "The portal service answered something that could not be read."
            }
        }

        /// No usable host is available for this episode — **the same refusal as the server's**
        /// (`stream.no_host`), when the app itself establishes that all are blocked.
        ///
        /// The code is assembled: it is a server code and not a language key, and
        /// `scripts/strings.py` would otherwise read it as one.
        static var noHost: TestError {
            .cancelled(status: 404, code: "stream" + ".no_host", values: [:])
        }

        /// The code, if it was one — for everything that switches on a case.
        public var code: String? {
            if case .cancelled(_, let code, _) = self { return code }
            return nil
        }
    }

    // ── Abrufen ──────────────────────────────────────────────────────────────

    func fetch<T: Decodable>(_ route: String, _ query: [String: String] = [:]) async throws -> T {
        let translated = dialect.asks(query)
        var split = URLComponents(
            url: basis.appendingPathComponent(dialect.route(route)), resolvingAgainstBaseURL: false)
        split?.queryItems =
            translated.isEmpty
            ? nil
            : translated.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
        guard let url = split?.url else { throw TestError.unreadable }

        var request = URLRequest(url: url)
        // A portal script needs time: the service loads a foreign page, reads patterns and
        // afterwards resolves the host. A default of three seconds would be the most frequent
        // cause of errors, and not a real one.
        request.timeoutInterval = 60
        render(&request)

        return try await send(request)
    }

    func notify<K: Encodable & Sendable, T: Decodable>(_ route: String, mainContent: K) async throws -> T {
        var request = URLRequest(url: basis.appendingPathComponent(dialect.route(route)))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? writer.encode(mainContent)
        request.timeoutInterval = 20
        render(&request)
        return try await send(request)
    }

    /// A `DELETE` that comes back **with a response** — revoking the person token delivers
    /// the new one right along (AP47).
    func remove<T: Decodable>(_ route: String) async throws -> T {
        var request = URLRequest(url: basis.appendingPathComponent(dialect.route(route)))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20
        render(&request)
        return try await send(request)
    }

    /// The token on the request — **on every one, without exception.**
    ///
    /// If it is missing, the server answers `401 auth.required`; forgetting it on individual
    /// paths would mean having individual screens empty and not the app.
    private func render(_ request: inout URLRequest) {
        guard dialect.needsMarker else { return }
        if let trait { request.setValue(trait, forHTTPHeaderField: PortalDialect.markerHeader) }
        if let profile { request.setValue(profile, forHTTPHeaderField: PortalDialect.profileHeader) }
    }

    /// **The one place where every portal request ends — if it fails, it is recorded here.**
    ///
    /// Until 2026-09-27 only individual callers logged their own failure (``SignInState``,
    /// the settings); everything that ran directly through ``fetch(_:_:)``,
    /// ``notify(_:mainContent:)`` or ``remove(_:)`` stayed silent if nobody above thought of
    /// it. One line here covers every path at once.
    ///
    /// **Never the address.** `Diagnostics.explain` cuts what carries `://` — a search term
    /// or a portal path would otherwise come along with the error.
    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let reply: URLResponse
        do {
            (data, reply) = try await session.data(for: request)
        } catch {
            // **A cancellation is not a defect** (finding 12): whoever keeps scrolling cancels the
            // request of the previous level — `defect(_:error:…)` then puts it only in the
            // verbose log.
            Diagnostics.defect(
                "Portal request unreachable", error: error, since: nil, area: "Portal")
            throw TestError.unreachable(underlying: error)
        }

        if let http = reply as? HTTPURLResponse, http.statusCode >= 400 {
            let error = Self.rejection(from: data, status: http.statusCode)
            // **"No state" is an answer and not a defect** (diagnosis F-025, 2026-09-28): a
            // title nobody has watched yet has no state, and the server says so with
            // `state.unknown_key`. In the report it appeared as an error.
            if case .cancelled(_, let code, _) = error, code == "state.unknown_key" {
                Diagnostics.verbose("Portal request: no state yet for this title")
            } else {
                // **With the path, without the query** (2026-09-29): a 404 on the iPhone toppled the
                // whole CL-Server source, and the report did not show which request it was. The query
                // stays out — identifiers are in it.
                Diagnostics.defect(
                    "Portal request rejected (\(request.httpMethod ?? "GET") \(request.url?.path ?? "?")): "
                        + Diagnostics.explain(error), since: nil, area: "Portal")
            }
            throw error
        }
        guard let read = try? reader.decode(T.self, from: data) else {
            Diagnostics.defect("Portal response unreadable", since: nil, area: "Portal")
            throw TestError.unreadable
        }
        return read
    }

    // ── Reading and writing ───────────────────────────────────────────────────

    /// A reader that translates the service's words into the bridge's.
    ///
    /// **Before mapping the keys and not after:** `keyDecodingStrategy` runs before
    /// `CodingKeys` applies — `duration_min` becomes `dauer_minuten` here, and the models
    /// then find their familiar word. That is why **not a single** DTO has to be touched in
    /// order to read the second service.
    private var reader: JSONDecoder {
        let reader = JSONDecoder()
        guard dialect == .cinelounge else { return reader }
        let dialect = dialect
        reader.keyDecodingStrategy = .custom { path in DialectKey(dialect.key(path: path)) }
        return reader
    }

    /// The same way back, for everything the app sends.
    private var writer: JSONEncoder {
        let writer = JSONEncoder()
        guard dialect == .cinelounge else { return writer }
        let dialect = dialect
        writer.keyEncodingStrategy = .custom { path in
            DialectKey(dialect.outgoingKey(path: path))
        }
        return writer
    }

    // ── Absagen ──────────────────────────────────────────────────────────────

    /// What is in a refusal — a code at the server, a text at the bridge.
    ///
    /// **Without a reason a code and no German substitute sentence** (check 2026-09-27,
    /// design B2): `portal.rejected` with the status as placeholder; the app looks up the
    /// sentence. Assembled, because `scripts/strings.py` would otherwise read it as a
    /// language key.
    static func rejection(from data: Data, status: Int) -> TestError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let wrapper = object?["error"] as? [String: Any], let code = wrapper["code"] as? String {
            // `values` carries numbers like strings; as text both suit a placeholder, and passing
            // an `Any` through the app suits nothing.
            let values = (wrapper["values"] as? [String: Any] ?? [:]).compactMapValues {
                $0 as? String ?? ($0 as? CustomStringConvertible).map(String.init(describing:))
            }
            return .cancelled(status: status, code: code, values: values)
        }
        if let reason = reason(from: data) {
            return .rejected(status: status, reason: reason)
        }
        return .cancelled(status: status, code: "portal" + ".rejected", values: ["status": "\(status)"])
    }

    /// Fetch the reason from `{"detail": "…"}` — `nil` if the response names none.
    static func reason(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let detail = object["detail"] as? String, !detail.isEmpty
        else { return nil }
        return detail
    }

}

/// A key that is already translated.
///
/// `JSONDecoder.KeyDecodingStrategy.custom` demands a `CodingKey` back and not a
/// string; this type is no more than its carrier.
struct DialectKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ word: String) { stringValue = word }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
