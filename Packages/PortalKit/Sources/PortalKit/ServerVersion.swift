import Foundation

/// Who answers at this address — **asked, not guessed.**
///
/// **The finding (2026-09-12):** there are two services that answer the same questions, and for a
/// while both will exist. The switchover must therefore not hang on a switch that someone has to
/// flip: whoever forgets it has an app that finds nothing, and no hint as to why.
///
/// The server answers `/.well-known/cinelounge` **without any header and always with 200**. The
/// bridge does not know the path and answers 404. That makes the question "who am I talking to" a
/// request and not an assumption — and the app serves both without anyone configuring anything.
public struct ServerVersion: Sendable, Equatable {

    /// What the household calls itself — "Home".
    public let name: String
    public let version: String
    /// Which versions of the contract the server speaks. Since AP47 `[1, 2]`.
    public let api: [Int]
    public let languages: [String]
    /// What one logs in with. Today always `pin`.
    public let login: String
    /// **Fresh server, no person yet.** Then no path leads through the app — the console does that in
    /// the browser.
    public let setupRequired: Bool
    /// What this server can do: `household`, `join`, `portals`, `state`, `stream`.
    public let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case name, api
        case version = "version"
        case languages = "languages"
        case login = "auth"
        case setupRequired = "setup_required"
        case capabilities = "capabilities"
    }

    /// The path under which a server identifies itself.
    public static let route = ".well-known/cinelounge"

    // ── Fragen ───────────────────────────────────────────────────────────────

    /// Who answers at this address.
    ///
    /// - Returns: ``PortalDialect/cinelounge`` including version if a server reports in;
    ///   ``PortalDialect/bridge`` without a version if something else stands there.
    ///
    /// **A 404 is an answer and not an error.** It means "the old bridge is here", and that is a
    /// usable service. An error is thrown only if **nothing at all** answers — then the address is
    /// wrong or the machine is off, and the viewer has to learn that.
    public static func probe(
        _ basis: URL, session: URLSession = .shared
    ) async throws -> (dialect: PortalDialect, version: ServerVersion?) {
        var request = URLRequest(url: basis.appendingPathComponent(route))
        // **Short, and deliberately shorter than any other request.** This is the first question after
        // the start; it only decides which language applies. A minute of patience as with the portal script
        // would mean a minute of black screen.
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let reply: URLResponse
        do {
            (data, reply) = try await session.data(for: request)
        } catch {
            throw PortalBridge.TestError.unreachable(underlying: error)
        }

        guard let http = reply as? HTTPURLResponse, http.statusCode == 200,
            let read = try? JSONDecoder().decode(ServerVersion.self, from: data)
        else {
            return (.bridge, nil)
        }
        return (.cinelounge, read)
    }

    /// Does this server speak a contract version that this app knows?
    ///
    /// **Separate from the probe**, because the two demand different answers: an unknown server is
    /// the old bridge and is served; a CineLounge server with a version from the future is **not** a
    /// fallback to the bridge, but an app that is too old — and that is a sentence the viewer must
    /// read.
    ///
    /// **`2` since AP47 (2026-09-24):** the app speaks the join (``Join``). Whether it *offers*
    /// it is nevertheless decided by ``canJoin`` and not by this number.
    public static let knownVersions: Set<Int> = [1, 2]

    public var recognized: Bool { api.contains { Self.knownVersions.contains($0) } }
}

extension ServerVersion: Decodable {}
