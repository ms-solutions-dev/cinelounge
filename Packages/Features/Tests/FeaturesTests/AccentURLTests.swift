import Core
import Foundation
import JellyfinKit
import Testing

@testable import Features

/// Whether the address for the colour extraction carries the image tag.
///
/// **Measured against the server:** Without `tag` it answers without `max-age`, and
/// `URLCache` requests the image over the network again on every focus change — each of
/// these requests occupies one of the three image fetch slots that actually belong to
/// the visible tiles. The error is silent: The colour is still right, just slow and at
/// the expense of the posters.
@Suite("Color extraction: address with tag")
struct AccentURLTests {

    static func makeSource() -> JellyfinSource {
        JellyfinSource(
            credentials: ServerCredentials(
                serverURL: URL(string: "https://example.invalid")!,
                userID: "pruefnutzer",
                username: "pruefnutzer",
                accessToken: "kein-echter-schluessel"
            ),
            deviceID: "pruefgeraet"
        )
    }

    static let withBackdrop = MediaItem(
        id: "titel1",
        kind: .series,
        title: "Siege on Corvane",
        artwork: Artwork(
            posterID: "titel1", backdropID: "titel1",
            posterTag: "poster-tag", backdropTag: "backdrop-tag"
        )
    )

    static let posterOnly = MediaItem(
        id: "titel2",
        kind: .movie,
        title: "Kazemi",
        artwork: Artwork(posterID: "titel2", posterTag: "poster-tag-2")
    )

    static func tagValue(in url: URL?) -> String? {
        guard let url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return components.queryItems?.first { $0.name == "tag" }?.value
    }

    @MainActor
    @Test("Library and Home pass the tag along")
    func libraryAndHomeCarryTheTag() {
        let source = Self.makeSource()
        let library = LibraryModel(
            source: source,
            library: Core.Library(id: "lib1", name: "Serien", kind: .series)
        )
        let home = HomeModel(source: source)

        // With a background image: its tag, not that of the poster.
        #expect(Self.tagValue(in: library.accentSourceURL(for: Self.withBackdrop)) == "backdrop-tag")
        #expect(Self.tagValue(in: home.accentSourceURL(for: Self.withBackdrop)) == "backdrop-tag")

        // Without a background image the colour extraction falls back to the poster — then its
        // tag has to come along too.
        #expect(Self.tagValue(in: library.accentSourceURL(for: Self.posterOnly)) == "poster-tag-2")
        #expect(Self.tagValue(in: home.accentSourceURL(for: Self.posterOnly)) == "poster-tag-2")
    }

    @MainActor
    @Test("Search passes the tag along")
    func searchCarriesTheTag() {
        let model = SearchModel(source: Self.makeSource())
        #expect(Self.tagValue(in: model.accentSourceURL(for: Self.withBackdrop)) == "backdrop-tag")
        #expect(Self.tagValue(in: model.accentSourceURL(for: Self.posterOnly)) == "poster-tag-2")
    }
}
