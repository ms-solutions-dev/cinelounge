import Core
import Foundation
import Testing

@testable import JellyfinKit

/// **Clearing away and signing in at once** (AP75, 2026-10-11): `streamURL` first ended the old
/// encoding and then asked for the new session — two round trips where one suffices.
@Suite("Stream URL: cleanup and sign-in overlap")
struct StreamURLConcurrencyTests {

    @Test("DELETE ActiveEncodings and POST PlaybackInfo run concurrently")
    func overlap() async throws {
        SessionStub.forget()
        let source = JellyfinSource(
            credentials: ServerCredentials(
                serverURL: URL(string: "https://sessionstub.test")!,
                userID: "pruefnutzer", username: "pruefnutzer",
                accessToken: "not-a-real-key"),
            deviceID: "check-device", cacheLifetime: .seconds(3600),
            trustStore: CertificateTrustStore(), protocols: [SessionStub.self])
        let hls = PlaybackDecision(engine: .native, delivery: .hls, reason: .nativeContainer)

        // First title: only sign in, nothing to clear away.
        _ = try await source.streamURL(for: "a", decision: hls)
        #expect(SessionStub.runs.map(\.path) == ["/Items/a/PlaybackInfo"])

        // Second title: the old session goes, the new one comes — overlapping.
        _ = try await source.streamURL(for: "b", decision: hls)
        let deletion = try #require(SessionStub.runs.first { $0.path == "/Videos/ActiveEncodings" })
        let signIn = try #require(SessionStub.runs.first { $0.path == "/Items/b/PlaybackInfo" })
        #expect(
            deletion.start < signIn.end && signIn.start < deletion.end,
            "sequentially: \(SessionStub.runs)")
    }
}

/// Answers everything with `{}` — after 400 ms, so that two requests can overlap — and notes
/// path, start and end for each request.
final class SessionStub: URLProtocol {

    struct Run: CustomStringConvertible {
        let path: String
        let start: Date
        let end: Date
        var description: String { "\(path) \(Int(end.timeIntervalSince(start) * 1000)) ms" }
    }

    nonisolated(unsafe) private static var _runs: [Run] = []
    private static let lock = NSLock()
    static var runs: [Run] { lock.withLock { _runs } }
    static func forget() { lock.withLock { _runs.removeAll() } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == "sessionstub.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [self] in
            Self.lock.withLock { Self._runs.append(Run(path: url.path(), start: start, end: Date())) }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
