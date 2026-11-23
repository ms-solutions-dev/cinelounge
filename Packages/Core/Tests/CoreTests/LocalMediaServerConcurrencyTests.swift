import Foundation
import Testing

@testable import Core

/// **A hanging build does not hold the whole server** (AP72, 2026-10-11). Until then the
/// provider ran on a single serial queue: An MKV piece with a 20 s deadline made the list and
/// the neighbouring piece wait. Now the server answers "fast" while "slow" is still building.
@Suite("Local server: concurrent delivery")
struct LocalMediaServerConcurrencyTests {

    @Test("A slow piece does not block a fast one")
    func fastBeforeSlow() async throws {
        let server = try LocalMediaServer()
        server.provider = { name in
            if name == "slow.m4s" { Thread.sleep(forTimeInterval: 1.5) }
            return (Data(name.utf8), "video/mp4")
        }
        try await server.start()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        let slow = URL(string: server.address("slow.m4s"))!
        let fast = URL(string: server.address("fast.m4s"))!

        let start = Date()
        async let first = session.data(from: slow)
        try await Task.sleep(for: .milliseconds(150))
        let (fastData, _) = try await session.data(from: fast)
        let fastAfter = Date().timeIntervalSince(start)
        let (slowData, _) = try await first
        let slowAfter = Date().timeIntervalSince(start)

        #expect(String(decoding: fastData, as: UTF8.self) == "fast.m4s")
        #expect(String(decoding: slowData, as: UTF8.self) == "slow.m4s")
        #expect(fastAfter < 1.0, "fast came only after \(fastAfter) s — behind the slow one")
        #expect(slowAfter >= 1.4)
    }

    @Test("A missing piece is still a 404")
    func notPresent() async throws {
        let server = try LocalMediaServer()
        server.provider = { _ in nil }
        try await server.start()
        defer { server.stop() }
        let (_, reply) = try await URLSession(configuration: .ephemeral).data(
            from: URL(string: server.address("none.m4s"))!)
        #expect((reply as? HTTPURLResponse)?.statusCode == 404)
    }
}
