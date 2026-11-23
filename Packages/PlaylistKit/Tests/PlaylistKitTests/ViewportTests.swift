import Core
import Foundation
import Testing

@testable import PlaylistKit

/// The channel lists **per profile** (on-device test build 1332, 2026-09-27, findings 1 and 3): the
/// list lives on the device, but is seen only by the person who keeps it.
@Suite("Viewport of the channel lists")
@MainActor
struct ViewportTests {

    private func list(_ id: String) -> Playlist {
        Playlist(id: id, name: id, kind: .m3u(URL(string: "http://server/\(id).m3u")!))
    }

    private func catalog() -> PlaylistStore {
        let storage = PlaylistStore(
            store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        storage.add(list("a"))
        storage.add(list("b"))
        return storage
    }

    @Test("A new profile without a list sees none — neither in the live catalog nor merged")
    func emptyWindow() {
        let storage = catalog()
        storage.viewport = { [] }

        #expect(storage.enabledPlaylists.isEmpty)
        #expect(storage.visiblePlaylists.isEmpty)
        let channels = Channel(
            id: "a#ZINNE#1", name: "ZINNE", streamURL: URL(string: "http://a/1")!, playlistID: "a")
        #expect(storage.merged(["a": [channels]]).isEmpty)
        // The store itself keeps both — they belong to other profiles.
        #expect(storage.playlists.map(\.id) == ["a", "b"])
    }

    @Test("A profile sees exactly its lists, without a window all apply")
    func ownLists() {
        let storage = catalog()
        #expect(storage.enabledPlaylists.map(\.id) == ["a", "b"])

        storage.viewport = { ["b"] }
        #expect(storage.enabledPlaylists.map(\.id) == ["b"])
        #expect(storage.visiblePlaylists.map(\.id) == ["b"])

        storage.viewport = { nil }
        #expect(storage.enabledPlaylists.map(\.id) == ["a", "b"])
    }
}
