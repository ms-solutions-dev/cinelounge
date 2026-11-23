import Foundation
import Testing

@testable import Core
@testable import PlaylistKit

/// **The download behind the episode index.**
///
/// What is tested here is not the parsing (that lives in
/// ``SeriesEpisodeIndexTests``) but the behavior around it: the display
/// must never wait for the 11 MB fetch, a failure must not mark anything,
/// and a state fetched once must survive a restart.
///
/// **One after another and not side by side** (`.serialized`): the tests share
/// the responder of the network stub.
@Suite("Cache of the episode index", .serialized)
struct SeriesEpisodeIndexStoreTests {

    private func endpoint() throws -> XtreamEndpoint {
        try #require(XtreamEndpoint(server: "http://panel.test:80", username: "u", password: "p"))
    }

    private func store(_ directory: URL) -> SeriesEpisodeIndexStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlaylistStub.self]
        return SeriesEpisodeIndexStore(
            directory: directory, session: URLSession(configuration: config))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folgen-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A list with enough series to pass the threshold.
    private func playlist(seriesCount: Int) -> Data {
        var text = "#EXTM3U\n"
        for i in 0..<seriesCount {
            text += "#EXTINF:-1,Serie \(i) S01 E01\nhttp://panel.test/series/u/p/\(i).mkv\n"
        }
        return Data(text.utf8)
    }

    /// **The first look waits for nothing.** The very first time there is no
    /// state yet — and the library must still appear immediately.
    @Test("Without a state nothing comes back immediately")
    func firstCallReturnsNothing() async throws {
        PlaylistStub.answer = .success(playlist(seriesCount: 150))
        let directory = temporaryDirectory()
        let sut = store(directory)

        #expect(await sut.index(for: "liste", endpoint: try endpoint()) == nil)
    }

    /// And afterwards it is there — fetched, parsed, on disk.
    @Test("The caught-up state survives the restart")
    func refreshLandsOnDisk() async throws {
        PlaylistStub.answer = .success(playlist(seriesCount: 150))
        let directory = temporaryDirectory()
        let sut = store(directory)

        _ = await sut.index(for: "liste", endpoint: try endpoint())
        try await waitForIndex(in: directory)

        // A **new** download store on the same directory — as after a
        // restart of the app.
        let fresh = store(directory)
        let index = await fresh.index(for: "liste", endpoint: try endpoint())
        #expect(index?.titles.count == 150)
        #expect(index?.hasEpisodes("Serie 7") == true)
    }

    /// **An error page must not mark anything.** `get.php` was blocked at this
    /// provider for months with `884`; if an empty index came out of that,
    /// the whole catalog would suddenly be "without episodes".
    @Test("An error code leaves no state")
    func errorStatusLeavesNothing() async throws {
        PlaylistStub.answer = .status(884)
        let directory = temporaryDirectory()
        let sut = store(directory)

        _ = await sut.index(for: "liste", endpoint: try endpoint())
        try await settle()
        #expect(await store(directory).index(for: "liste", endpoint: try endpoint()) == nil)
    }

    /// The same for a response that does arrive but is too thin.
    @Test("A list that is too thin is discarded")
    func thinPlaylistIsDiscarded() async throws {
        PlaylistStub.answer = .success(playlist(seriesCount: 3))
        let directory = temporaryDirectory()
        let sut = store(directory)

        _ = await sut.index(for: "liste", endpoint: try endpoint())
        try await settle()
        #expect(await store(directory).index(for: "liste", endpoint: try endpoint()) == nil)
    }

    /// **Not a new fetch on every look.** Opening a category must not
    /// cost 11 MB when the state is from this morning.
    @Test("A fresh state triggers no second fetch")
    func freshIndexIsNotRefetched() async throws {
        PlaylistStub.answer = .success(playlist(seriesCount: 150))
        let directory = temporaryDirectory()
        let sut = store(directory)

        // **First let the trailing tasks of the previous test run out** (2026-09-11).
        //
        // `.serialized` orders the **tests**, not the background fetches they
        // start: ``SeriesEpisodeIndexStore/index(for:endpoint:)`` returns immediately
        // and fetches on the side. A fetch from the test before therefore landed in this
        // one — visible as "7 instead of 6", and only in the full run, never alone.
        //
        // **This is the fourth kind of shared state in this project** (AP25: the
        // network guard; AP26: the Keychain; AP26/27: the MainActor binding of
        // metrics), and like the other three, the justification stood next to it for
        // why it must work out.
        try await settle()
        PlaylistStub.calls = 0

        _ = await sut.index(for: "liste", endpoint: try endpoint())
        try await waitForIndex(in: directory)
        let afterFirst = PlaylistStub.calls

        for _ in 0..<5 { _ = await sut.index(for: "liste", endpoint: try endpoint()) }
        try await settle()
        #expect(PlaylistStub.calls == afterFirst)
    }

    // MARK: - Warten

    /// Waits until the background fetch has written the file.
    private func waitForIndex(in directory: URL) async throws {
        for _ in 0..<100 {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            if files.contains(where: { $0.hasPrefix("cinelounge-folgen-") }) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("The index was not written")
    }

    /// Gives the background fetch time, so that "nothing happens" is reliable.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 400_000_000)
    }
}

/// Answers `get.php` without needing a network.
///
/// `nonisolated(unsafe)`, because `URLProtocol` is called by Foundation from its own
/// thread and provides no place for state.
///
/// **And `.serialized` alone does not carry this** (corrected on 2026-09-11). It used to say
/// "permissible because the tests run one after another" — that orders the tests, not
/// the **background fetches** they start. Whoever counts ``calls`` therefore also counts
/// what the previous test still pushes in afterwards, and must let it run out first.
final class PlaylistStub: URLProtocol {

    enum Answer {
        case success(Data)
        case status(Int)
    }

    nonisolated(unsafe) static var answer: Answer = .status(404)
    nonisolated(unsafe) static var calls = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.calls += 1
        let url = request.url ?? URL(string: "http://panel.test")!
        switch Self.answer {
        case .success(let data):
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
        case .status(let code):
            let response = HTTPURLResponse(
                url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
