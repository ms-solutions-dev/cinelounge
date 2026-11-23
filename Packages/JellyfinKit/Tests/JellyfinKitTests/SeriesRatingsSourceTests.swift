import Core
import Foundation
import JellyfinAPI
import Testing

@testable import JellyfinKit

/// The source supplements episodes with the rating of their series (strand K, 2026-09-25) —
/// **checked against the real Continue Watching response** (`Fixtures/resume.json`): four
/// episodes without `OfficialRating`, one home video without.
@Suite("Series ratings in the source")
struct SeriesRatingsSourceTests {

    @Test("The collected fetch asks for all series in one request, with rating")
    func query() {
        let query = JellyfinSource.seriesRatingsQuery(["a1", "b2", "c3"])
        #expect(query == ["Ids": "a1,b2,c3", "Fields": "OfficialRating"])
    }

    /// **Over the connection:** the source reaches no server, the lookup fails — the episodes stay
    /// open, the home video does not. Open means locked in child mode; see `SeriesApprovalsTests`
    /// in `ParentalControls`.
    @Test("Without a server the episodes of the real response stay open")
    func withoutServerOpen() async throws {
        let reply = try ItemMappingTests.fixture("resume", as: BaseItemDtoQueryResult.self)
        let source = ListCacheTests.makeSource()
        let title = await source.mapped(reply.items ?? [])

        let episodes = title.filter { $0.kind == .episode }
        #expect(episodes.count == 4)
        #expect(episodes.allSatisfy { $0.ageRating == nil && $0.awaitsSeriesClearance })
        #expect(title.filter { $0.kind == .homeVideo }.allSatisfy { !$0.awaitsSeriesClearance })
    }

    /// **Over the connection, with a server:** a stub answers the collected fetch. Three series,
    /// **one** fetch; the episodes then carry the rating of their series, and a second pass does
    /// not ask again.
    @Test("With a server the episodes inherit their series' rating, in one fetch")
    func withServer() async throws {
        let reply = try ItemMappingTests.fixture("resume", as: BaseItemDtoQueryResult.self)
        SeriesStub.approvals = [
            "a5891368db58d9aa9c01d3dfd424d6b9": "FSK-16",
            "700e8818d9ff7cbad6d399f0e7f0d01c": "FSK-12",
            "cc73828c7e16ca8a35fcdc440abf252e": "FSK-18",
        ]
        SeriesStub.fetches = []

        let source = JellyfinSource(
            credentials: ServerCredentials(
                serverURL: URL(string: "https://serienstub.test")!,
                userID: "pruefnutzer", username: "pruefnutzer",
                accessToken: "not-a-real-key"),
            deviceID: "check-device", cacheLifetime: .seconds(3600),
            trustStore: CertificateTrustStore(), protocols: [SeriesStub.self])
        let title = await source.mapped(reply.items ?? [])
        _ = await source.mapped(reply.items ?? [])

        let perEpisode = Dictionary(
            uniqueKeysWithValues: title.filter { $0.kind == .episode }.map { ($0.id, $0.ageRating) })
        #expect(perEpisode["64492e2e458fca6c03eeda883f0520e8"] == "FSK-16")
        #expect(perEpisode["67ac5ed0436897b1361ec82f3f03fdae"] == "FSK-12")
        #expect(perEpisode["c9cbc30c5ba35fbc2669676e201d884d"] == "FSK-18")
        #expect(title.allSatisfy { !$0.awaitsSeriesClearance })
        #expect(SeriesStub.fetches.count == 1)
        #expect(SeriesStub.fetches.first?.split(separator: ",").count == 3)
    }
}

/// Answers `Users/{id}/Items?Ids=…` like the real server: one row with `OfficialRating` per
/// known series. `nonisolated(unsafe)` for the same reason as with `AuthorizeStub`.
final class SeriesStub: URLProtocol {

    nonisolated(unsafe) static var approvals: [String: String] = [:]
    nonisolated(unsafe) static var fetches: [String] = []

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == "serienstub.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let ids =
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "Ids" }?.value ?? ""
        Self.fetches.append(ids)
        let items = ids.split(separator: ",").compactMap { id -> [String: String]? in
            Self.approvals[String(id)].map { ["Id": String(id), "Type": "Series", "OfficialRating": $0] }
        }
        let body = try! JSONSerialization.data(withJSONObject: [
            "Items": items, "TotalRecordCount": items.count,
        ])
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
