import Core
import Foundation
import Testing

@testable import PlaylistKit

/// What is tested is the running programme in the Live area — above all what
/// **must not** happen.
///
/// The broadcast times are the only place in the app where every focus change
/// can trigger a network fetch. With a typical provider, four of five
/// channels have no programme ID, and only about one in ten finds an
/// entry at all; the complete programme file runs to tens of MiB and would be
/// a half-hour operation over a slow tunnel. A bug here therefore does not show up as a wrong
/// display but as an app that stalls while scrolling through the channel list.
/// These checks aim at exactly that: they count fetches.
///
/// **No test case touches the network.** The Xtream side runs via an
/// injected source that counts instead of answering; the XMLTV side via
/// files in the file system.
@Suite("Running programme")
@MainActor
struct LiveGuideTests {

    // MARK: - Hilfen

    /// A provider that does not answer but keeps a log.
    ///
    /// The counter is the actual subject under test: whether a channel gets a programme
    /// is also visible in the result — whether it was asked for once, twice or not
    /// at all, only here.
    private actor RecordingSource: ChannelSource {
        let playlist: Playlist
        private let answers: [String: [Programme]]
        private let delay: Duration?
        private var isFailing: Bool
        private(set) var requests: [String] = []

        init(
            playlist: Playlist,
            answers: [String: [Programme]] = [:],
            isFailing: Bool = false,
            delay: Duration? = nil
        ) {
            self.playlist = playlist
            self.answers = answers
            self.isFailing = isFailing
            self.delay = delay
        }

        func channels() async throws -> [Channel] { [] }

        func programmes(for channelID: String, around date: Date) async throws -> [Programme] {
            requests.append(channelID)
            if let delay { try? await Task.sleep(for: delay) }
            if isFailing { throw XtreamClient.Failure.unreachable }
            return answers[channelID] ?? []
        }

        func stopFailing() { isFailing = false }
    }

    private func makeStore() -> PlaylistStore {
        PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
    }

    private func xtreamPlaylist(id: String = "liste1") -> Playlist {
        Playlist(
            id: id,
            name: "Anbieter",
            kind: .xtream(server: URL(string: "http://panel.example:8080")!, username: "benutzer")
        )
    }

    private func m3uPlaylist(id: String = "liste2", epgURL: URL?) -> Playlist {
        Playlist(
            id: id,
            name: "Datei",
            kind: .m3u(URL(string: "http://server/liste.m3u")!),
            epgURL: epgURL
        )
    }

    /// A channel as the Xtream parser builds it: ID with list ID
    /// and provider number.
    private func channel(
        list: String = "liste1",
        streamID: Int = 771_001,
        epgID: String? = "democinema.de"
    ) -> Channel {
        Channel(
            id: XtreamPayload.channelID(playlistID: list, streamID: streamID),
            name: "DEMO CINEMA",
            streamURL: URL(string: "http://panel.example:8080/live/\(streamID).ts")!,
            playlistID: list,
            epgID: epgID
        )
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil),
            "Fixture \(name) is missing from the test bundle"
        )
        return try Data(contentsOf: url)
    }

    private func fixtureURL(_ name: String) throws -> URL {
        try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil),
            "Fixture \(name) is missing from the test bundle"
        )
    }

    /// The four broadcasts from the fixture `short_epg.json`, parsed as
    /// in production.
    private func recordedProgrammes(channelID: String) throws -> [Programme] {
        let payload = try XtreamPayload.decoder.decode(
            XtreamPayload.EPGResponse.self,
            from: try fixture("short_epg.json")
        )
        return XtreamPayload.programmes(from: payload.epgListings ?? [], channelID: channelID)
    }

    /// Puts a file into temporary storage and returns it together with its cleanup.
    private func temporaryFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cinelounge-pruefung-\(UUID().uuidString).xml")
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: - Der Normalfall

    @Test("A channel gets the broadcasts from the provider's response")
    func programmesFromProvider() async throws {
        // The whole path in one piece: channel, assignment to the list, fetch,
        // parsing. Tested against a response in the provider's form, because its
        // titles and descriptions arrive base-encoded — an invented
        // example with plain text would leave unchecked exactly the step that
        // decides whether the screen shows a title or gibberish.
        let store = makeStore()
        let playlist = xtreamPlaylist()
        store.add(playlist, password: "geheim")

        let channel = channel()
        let source = RecordingSource(
            playlist: playlist,
            answers: [channel.id: try recordedProgrammes(channelID: channel.id)]
        )

        let library = LiveLibrary(store: store)
        await library.install(source, for: playlist.id)

        let programmes = await library.programmes(for: channel)

        #expect(programmes.count == 4)
        #expect(programmes.first?.title == "Grauwacke III")
        #expect(programmes.first?.description?.hasPrefix("Die Kartografinnen sind zurück") == true)
        #expect(await source.requests == [channel.id])
    }

    @Test("The broadcasts come ordered by start time")
    func programmesAreSorted() async throws {
        // XMLTV guarantees no order, and real files exploit that. The
        // view takes the first broadcast as "running now", though — with an
        // unordered list the repeat from last night would stand there.
        let store = makeStore()
        let file = try temporaryFile(
            """
            <?xml version="1.0" encoding="UTF-8"?><tv>
            <programme start="20260728220000 +0000" stop="20260728230000 +0000" channel="test.de">
              <title>Spät</title>
            </programme>
            <programme start="20260728080000 +0000" stop="20260728090000 +0000" channel="test.de">
              <title>Früh</title>
            </programme>
            </tv>
            """
        )
        defer { try? FileManager.default.removeItem(at: file) }

        let playlist = m3uPlaylist(epgURL: file)
        store.add(playlist)

        let library = LiveLibrary(store: store)
        let programmes = await library.programmes(
            for: channel(list: playlist.id, epgID: "test.de")
        )

        #expect(programmes.map(\.title) == ["Früh", "Spät"])
    }

    // MARK: - What is not asked at all

    @Test("A channel without a program identifier triggers no request at all")
    func noEPGIDNoRequest() async throws {
        // The most important case of all: most channels of a typical provider
        // have no programme ID. Without this condition every
        // focus change while scrolling sends off a fetch that predictably comes back
        // empty — and the one fetch that matters queues up behind it.
        let store = makeStore()
        let playlist = xtreamPlaylist()
        store.add(playlist, password: "geheim")

        let source = RecordingSource(playlist: playlist)
        let library = LiveLibrary(store: store)
        await library.install(source, for: playlist.id)

        let programmes = await library.programmes(for: channel(epgID: nil))

        #expect(programmes.isEmpty)
        #expect(await source.requests.isEmpty, "nothing may be fetched without a program identifier")
    }

    @Test("A channel of a list that is no longer stored asks nobody")
    func unknownPlaylist() async throws {
        // If the user deletes a list while its channels are still on the screen,
        // the focus points at a channel without a list. That may result in an empty
        // row and not in a crash.
        let store = makeStore()
        let playlist = xtreamPlaylist()
        let source = RecordingSource(playlist: playlist)

        let library = LiveLibrary(store: store)
        await library.install(source, for: playlist.id)

        #expect(await library.programmes(for: channel()).isEmpty)
        #expect(await source.requests.isEmpty)
    }

    @Test("An M3U list without an EPG address yields nothing")
    func m3uWithoutGuide() async throws {
        // An M3U contains no broadcast times. If the list carries no XMLTV address,
        // there is nothing to fetch — not even if the channels in it carry a
        // `tvg-id`, which is the rule and not the exception.
        let store = makeStore()
        let playlist = m3uPlaylist(epgURL: nil)
        store.add(playlist)

        let library = LiveLibrary(store: store)
        let programmes = await library.programmes(
            for: channel(list: playlist.id, epgID: "PipacsMozi.hu")
        )

        #expect(programmes.isEmpty)
    }

    // MARK: - Zwischenspeicher

    @Test("The second look at the same channel does not go to the provider again")
    func secondLookIsCached() async throws {
        // While scrolling, the focus keeps returning to the same channel. Without a
        // cache every return costs a fetch over a connection of
        // 0.3 Mbit/s, and the display flickers between empty and filled.
        let store = makeStore()
        let playlist = xtreamPlaylist()
        store.add(playlist, password: "geheim")

        let channel = channel()
        let source = RecordingSource(
            playlist: playlist,
            answers: [channel.id: try recordedProgrammes(channelID: channel.id)]
        )

        let library = LiveLibrary(store: store)
        await library.install(source, for: playlist.id)

        let first = await library.programmes(for: channel)
        let second = await library.programmes(for: channel)

        #expect(first == second)
        #expect(await source.requests.count == 1)
    }

    @Test("Two simultaneous requests for the same channel yield one fetch")
    func concurrentRequestsShareOneFetch() async throws {
        // The focus moves faster than the provider answers: the second
        // request arrives while the first is still running. A store that only files the
        // result away would be empty at that moment and would send a
        // second fetch after it. The delay here reproduces exactly this
        // overlap — without it the second request would run only after the
        // first and the case would stay unchecked.
        let store = makeStore()
        let playlist = xtreamPlaylist()
        store.add(playlist, password: "geheim")

        let channel = channel()
        let source = RecordingSource(
            playlist: playlist,
            answers: [channel.id: try recordedProgrammes(channelID: channel.id)],
            delay: .milliseconds(80)
        )

        let library = LiveLibrary(store: store)
        await library.install(source, for: playlist.id)

        async let first = library.programmes(for: channel)
        async let second = library.programmes(for: channel)
        let (one, two) = await (first, second)

        #expect(one.count == 4)
        #expect(one == two)
        #expect(await source.requests.count == 1)
    }

    @Test("The XMLTV file is read only once for the whole list")
    func guideIsReadOncePerPlaylist() async throws {
        // XMLTV has no per-channel query: there is one file for everything. Fetching it
        // again for every channel would mean pulling the same megabytes
        // four hundred times over the connection.
        //
        // Counting happens without a counter: after the first channel the file disappears.
        // If the second channel still gets its programme, the file cannot have been read
        // a second time.
        let store = makeStore()
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("cinelounge-pruefung-\(UUID().uuidString).xml")
        try FileManager.default.copyItem(at: try fixtureURL("epg.xml"), to: copy)

        let playlist = m3uPlaylist(epgURL: copy)
        store.add(playlist)

        let library = LiveLibrary(store: store)
        let first = await library.programmes(
            for: channel(list: playlist.id, streamID: 1, epgID: "PipacsMozi.hu")
        )

        try FileManager.default.removeItem(at: copy)

        let second = await library.programmes(
            for: channel(list: playlist.id, streamID: 2, epgID: "KavicsHirek.hu")
        )

        #expect(first.count == 6)
        #expect(first.first?.title == "Éjféli vonat")
        #expect(second.count == 6, "the second channel must come from the file already read")
        #expect(second.first?.title == "Reggeli kérdések")
    }

    @Test("After invalidate() the broadcast times are fetched anew")
    func invalidateDropsProgrammes() async throws {
        // Broadcast times hang on channel IDs. After a changed list the
        // same ID can designate a different channel — a retained
        // programme would then show foreign broadcasts, and that looks plausible.
        // Nobody would notice the bug.
        let store = makeStore()
        let playlist = xtreamPlaylist()
        store.add(playlist, password: "geheim")

        let channel = channel()
        let source = RecordingSource(
            playlist: playlist,
            answers: [channel.id: try recordedProgrammes(channelID: channel.id)]
        )

        let library = LiveLibrary(store: store)
        await library.install(source, for: playlist.id)
        _ = await library.programmes(for: channel)

        await library.invalidate()
        await library.install(source, for: playlist.id)
        _ = await library.programmes(for: channel)

        #expect(await source.requests.count == 2)
    }

    // MARK: - Failures

    @Test("A failed fetch yields an empty list and is not kept")
    func failureIsEmptyAndNotRemembered() async throws {
        // Two statements in one case, because they belong together. First: a
        // failure must not be thrown — a channel without a programme is the
        // normal case, and the view omits the row instead of showing a message.
        // Second: it must not stay in the cache. Its
        // most common cause is the connection, not the channel; keeping it would mean that
        // a channel disturbed once stays empty until the next reload.
        let store = makeStore()
        let playlist = xtreamPlaylist()
        store.add(playlist, password: "geheim")

        let channel = channel()
        let source = RecordingSource(
            playlist: playlist,
            answers: [channel.id: try recordedProgrammes(channelID: channel.id)],
            isFailing: true
        )

        let library = LiveLibrary(store: store)
        await library.install(source, for: playlist.id)

        #expect(await library.programmes(for: channel).isEmpty)

        await source.stopFailing()
        let afterRecovery = await library.programmes(for: channel)

        #expect(afterRecovery.count == 4, "after the disruption the channel must try again")
        #expect(await source.requests.count == 2)
    }

    @Test("A missing XMLTV file yields an empty list")
    func missingGuideFile() async throws {
        // The user enters an address that points at nothing, or the file
        // is no longer there. That is a setup error and not one that
        // the channel list should pay for.
        let store = makeStore()
        let playlist = m3uPlaylist(
            epgURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("gibt-es-nicht-\(UUID().uuidString).xml")
        )
        store.add(playlist)

        let library = LiveLibrary(store: store)
        let programmes = await library.programmes(for: channel(list: playlist.id, epgID: "PipacsMozi.hu"))

        #expect(programmes.isEmpty)
    }
}
