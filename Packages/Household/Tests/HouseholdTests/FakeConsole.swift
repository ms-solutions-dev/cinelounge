import Foundation

/// A session that, instead of going to the network, reaches into one answer per **route** — one
/// own instance per check, so that checks running in parallel do not interfere with each other's line.
/// A route without an answer yields a network error: that is how "the server stays silent" is testable.
///
/// **The same design as the `FakeConsole` of the TV checks** (AP58 R2): The
/// household's checks moved here from `Features` along with it; the join checks
/// that stay there keep theirs.
final class FakeConsole: URLProtocol, @unchecked Sendable {

    struct Request: Sendable {
        let method: String
        let route: String
        let bodyContent: Data?
    }

    struct Wire: Sendable {
        let basis: URL
        var requestJoin: [Request] { FakeConsole.recorded(forItem: basis.host ?? "") }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: [String: (Int, Data)]] = [:]
    nonisolated(unsafe) private static var transcript: [String: [Request]] = [:]

    static let session: URLSession = {
        let setup = URLSessionConfiguration.ephemeral
        setup.protocolClasses = [FakeConsole.self]
        return URLSession(configuration: setup)
    }()

    static func setUp(_ routes: [String: (Int, Data)]) -> Wire {
        let calculator = "pruef-\(UUID().uuidString.lowercased()).invalid"
        lock.withLock { answers[calculator] = routes }
        return Wire(basis: URL(string: "http://\(calculator):8100")!)
    }

    static func recorded(forItem calculator: String) -> [Request] {
        lock.withLock { transcript[calculator] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let calculator = request.url?.host ?? ""
        let route = request.url?.path ?? ""
        var bodyContent = request.httpBody
        if bodyContent == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                collected.append(buffer, count: n)
            }
            stream.close()
            bodyContent = collected
        }
        let reply: (Int, Data)? = Self.lock.withLock {
            Self.transcript[calculator, default: []].append(
                Request(method: request.httpMethod ?? "GET", route: route, bodyContent: bodyContent))
            return Self.answers[calculator]?[route]
        }
        guard let (status, data) = reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let header = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: header, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
