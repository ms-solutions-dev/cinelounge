import Foundation
import Testing

@testable import JellyfinKit

/// The confirming side of Quick Connect — the device that is already signed in waves through
/// the new one's code.
@Suite("Authorizing Quick Connect", .serialized)
struct QuickConnectAuthorizeTests {

    let server = URL(string: "https://jellyfin.test")!

    func quickConnect() -> QuickConnect {
        QuickConnect(timeout: 2, protocols: [AuthorizeStub.self])
    }

    /// **The server answers with `true` or `false` — both with status 200.**
    ///
    /// This is the line where this function would silently go wrong: whoever looks only at the
    /// status code reports success and leaves the other screen waiting forever.
    @Test("A `false` with status 200 is a failure")
    func falseWithTwoHundred() async throws {
        AuthorizeStub.reply = .text(200, "false")
        await #expect(throws: QuickConnect.Failure.expired) {
            try await quickConnect().authorize(
                server: server, code: "123456", token: "t", deviceID: "d", deviceName: "n")
        }
    }

    @Test("A `true` with status 200 is the authorization")
    func isTrue() async throws {
        AuthorizeStub.reply = .text(200, "true")
        let ok = try await quickConnect().authorize(
            server: server, code: "123456", token: "t", deviceID: "d", deviceName: "n")
        #expect(ok)
    }

    /// **The code goes in the query and not in the body.** Jellyfin expects it exactly that way; a
    /// JSON body is silently ignored, and the response is then "false" without an error — so the
    /// same failure as above, only without a hint of what the cause was.
    @Test("The code travels in the query, the token in the header")
    func request() async throws {
        AuthorizeStub.reply = .text(200, "true")
        _ = try await quickConnect().authorize(
            server: server, code: "654321", token: "marke", deviceID: "d", deviceName: "n")

        #expect(AuthorizeStub.last?.url?.query?.contains("code=654321") == true)
        #expect(AuthorizeStub.last?.httpMethod == "POST")
        let header = AuthorizeStub.last?.value(forHTTPHeaderField: "Authorization")
        #expect(header?.contains(#"Token="marke""#) == true)
    }

    /// Without the feature the path does not exist — then the UI must offer the password and not
    /// wait forever.
    @Test("404 and 403 mean: the server does not offer it")
    func disabled() async throws {
        for status in [403, 404] {
            AuthorizeStub.reply = .text(status, "")
            await #expect(throws: QuickConnect.Failure.notEnabled) {
                try await quickConnect().authorize(
                    server: server, code: "1", token: "t", deviceID: "d", deviceName: "n")
            }
        }
    }

    /// **Jellyfin 12 accepts `Initiate` only via POST now** (on-device test 2026-09-27): the app
    /// asked via GET, got 405 and reported "This server does not offer sign-in by code" — with
    /// Quick Connect switched on.
    @Test("The start goes by POST")
    func startViaPost() async throws {
        AuthorizeStub.reply = .text(200, #"{"Code":"587222","Secret":"geheim"}"#)
        let session = try await quickConnect().begin(server: server, deviceID: "d", deviceName: "n")
        #expect(session.code == "587222")
        #expect(AuthorizeStub.last?.httpMethod == "POST")
        #expect(AuthorizeStub.last?.url?.path == "/QuickConnect/Initiate")
    }

    @Test("An expired code reports as expired")
    func expired() async throws {
        for status in [400, 401] {
            AuthorizeStub.reply = .text(status, "")
            await #expect(throws: QuickConnect.Failure.expired) {
                try await quickConnect().authorize(
                    server: server, code: "1", token: "t", deviceID: "d", deviceName: "n")
            }
        }
    }
}

/// Supplies the server's responses. `nonisolated(unsafe)`, because `URLProtocol` is called by
/// Foundation from a thread of its own and has no room for state — the same justification as
/// for `PlaylistStub` in `PlaylistKit`.
final class AuthorizeStub: URLProtocol {

    enum Reply {
        case text(Int, String)
    }

    nonisolated(unsafe) static var reply: Reply = .text(404, "")
    nonisolated(unsafe) static var last: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.last = request
        let url = request.url ?? URL(string: "https://jellyfin.test")!
        switch Self.reply {
        case .text(let status, let content):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !content.isEmpty { client?.urlProtocol(self, didLoad: Data(content.utf8)) }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
