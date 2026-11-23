import Core
import Foundation
import Testing

@testable import PortalKit

/// What the bridge sends becomes what the view shows.
@Suite("From the bridge to the view")
struct PortalConversionTests {

    private func entry(
        kind: String = "serie",
        state: BridgeReply.State? = nil,
        image: String? = "https://beispiel.invalid/plakat.jpg",
        year: Int? = 2006,
        duration: Int? = nil
    ) -> BridgeReply.ContentEntryRecord {
        let raw = """
            {"titel":"Chalk Line","adresse":"f=showSeasons&sUrl=x","art":"\(kind)",
             "jahr":\(year.map(String.init) ?? "null"),"beschreibung":"Ein Uhrmacher.",
             "bild":\(image.map { "\"\($0)\"" } ?? "null"),"bild_herkunft":"portal",
             "sprachen":["DE","EN"],"bewertung":8.9,
             "dauer_minuten":\(duration.map(String.init) ?? "null"),"nummer":null,
             "hat_kinder":true,"schluessel":"serieshub:chalk-line:2006",
             "stand":\(state == nil ? "null" : """
                {"anteil":0.25,"rest_s":1800.0,"position_s":600.0,"gesehen":false,"favorit":true}
                """)}
            """
        return try! JSONDecoder().decode(BridgeReply.ContentEntryRecord.self, from: Data(raw.utf8))
    }

    /// **The on-device finding, recorded as a check** (2026-08-28).
    ///
    /// Reported: videos still cannot be played — and the cause was not in the resolution
    /// chain but before it: without `source`, `startPlayback` silently returns before it
    /// even asks the bridge. The log showed exactly that: the TV fetched episodes and
    /// afterwards sent **not a single** `/sources`.
    @Test("Playable items carry their file details", arguments: ["folge", "film"])
    func playableCarriesDetails(_ kind: String) {
        let item = entry(kind: kind).asMediaItem(portal: "serieshub")
        #expect(
            item.source != nil,
            "\"\(kind)\" without file details silently does not play")
        #expect(item.source?.supportsDirectPlay == true)
    }

    /// The counter-test. A source on a folder would claim that it is a file — and the
    /// detail page would take it seriously.
    @Test(
        "What is not playable does not claim to be",
        arguments: ["ordner", "serie", "staffel", "trenner"])
    func unplayableStaysWithout(_ kind: String) {
        let item = entry(kind: kind).asMediaItem(portal: "serieshub")
        #expect(item.source == nil, "\"\(kind)\" is not a file")
    }

    /// **The on-device finding, recorded as a check** (2026-08-28, favorites).
    ///
    /// Reported: for favorites the poster content is not visible, and opening one shows
    /// "The server reports a fault" — although it works through the portal. Both came from
    /// the store turning every entry into an episode and carrying no image: the detail page
    /// of a series asked for an episode that does not exist.
    @Test(
        "A state entry keeps its kind",
        arguments: [("serie", MediaItem.Kind.series), ("film", .movie), ("folge", .episode)])
    func progressKeepsKind(_ scenario: (String, MediaItem.Kind)) throws {
        let raw = """
            {"schluessel":"serieshub:bowline:2014","portal":"serieshub","titel":"Bowline",
             "jahr":2014,"adresse":"f=showSeasons&sUrl=x","art":"\(scenario.0)",
             "bild":"/p/serieshub/bild?pfad=/daten/x.png","position_s":0.0,"dauer_s":0.0,
             "gesehen":false,"favorit":true,"anteil":0.0,"rest_s":null}
            """
        let row = try JSONDecoder().decode(
            BridgeReply.ProgressRow.self, from: Data(raw.utf8))
        let item = row.asMediaItem()
        #expect(item.kind == scenario.1)
        #expect(item.artwork.posterID == "/p/serieshub/bild?pfad=/daten/x.png")
    }

    /// An entry from before these columns must not disappear.
    @Test("An old state entry without a kind stays usable")
    func oldProgressStaysUsable() throws {
        let raw = """
            {"schluessel":"x:y:","portal":"x","titel":"Alt","jahr":null,"adresse":"a",
             "position_s":10.0,"dauer_s":100.0,"gesehen":false,"favorit":true,
             "anteil":0.1,"rest_s":90}
            """
        let row = try JSONDecoder().decode(
            BridgeReply.ProgressRow.self, from: Data(raw.utf8))
        let item = row.asMediaItem()
        #expect(item.kind == .episode)
        #expect(item.artwork.posterID == nil)
        #expect(item.title == "Alt")
    }

    /// AP63, 2026-10-01: "Details" from Continue Watching leads to the series — the row
    /// brings it along, and without it the episode stays.
    @Test("The series of an episode arrives as seriesID")
    func seriesArrives() throws {
        let raw = """
            {"schluessel":"x:y:","portal":"x","titel":"Folge","jahr":null,"adresse":"a",
             "art":"folge","position_s":10.0,"dauer_s":100.0,"gesehen":false,"favorit":false,
             "anteil":0.1,"rest_s":90,"serie":"x|x:serie:|f=showSeasons"}
            """
        let item = try JSONDecoder().decode(
            BridgeReply.ProgressRow.self, from: Data(raw.utf8)
        ).asMediaItem()
        #expect(item.seriesID == "x|x:serie:|f=showSeasons")
    }

    /// Round trip must give the same result, otherwise the two tables drift apart as soon
    /// as a kind is added.
    ///
    /// **Across both dialects (2026-09-12).** The kind is a **value** and is not covered by
    /// the key translation — the bridge writes `folder`, the server `folder`. Until this
    /// test covered both languages, every server folder fell into the `default` branch and
    /// became a series: thirty genres as posters, exactly the viewer finding of 2026-08-27 that
    /// `kindFromType` had already fixed once.
    @Test(
        "Kind there and back",
        arguments: [
            ("serie", PortalDialect.bridge), ("film", .bridge), ("staffel", .bridge),
            ("folge", .bridge), ("ordner", .bridge), ("trenner", .bridge),
            ("series", .cinelounge), ("movie", .cinelounge), ("season", .cinelounge),
            ("episode", .cinelounge), ("folder", .cinelounge), ("separator", .cinelounge),
            ("sammlung", .bridge), ("collection", .cinelounge),
        ])
    func kindRoundTrip(_ scenario: (kind: String, dialect: PortalDialect)) {
        let kind = BridgeReply.ContentEntryRecord.kindFromType(scenario.kind)
        #expect(BridgeReply.ContentEntryRecord.kindName(forItem: kind, in: scenario.dialect) == scenario.kind)
    }

    /// No kind may mean something different in the two languages.
    ///
    /// **The guard against the next vocabulary word.** If a kind is added and entered in only
    /// one of the two tables, it shows up here — and not only because a list on the TV
    /// looks wrong.
    @Test("Every kind has a word in both languages")
    func everyKindBilingual() {
        for kind in [MediaItem.Kind.movie, .season, .episode, .folder, .separator, .series, .collection] {
            let german = BridgeReply.ContentEntryRecord.kindName(forItem: kind, in: .bridge)
            let english = BridgeReply.ContentEntryRecord.kindName(forItem: kind, in: .cinelounge)
            #expect(german != nil, "no bridge vocabulary for \(kind)")
            #expect(english != nil, "no server vocabulary for \(kind)")
            #expect(german.map { BridgeReply.ContentEntryRecord.kindFromType($0) } == kind)
            #expect(english.map { BridgeReply.ContentEntryRecord.kindFromType($0) } == kind)
        }
    }

    @Test("An entry becomes a MediaItem, and the identifier carries the portal along")
    func baseCase() {
        let item = entry().asMediaItem(portal: "serieshub")
        #expect(item.title == "Chalk Line")
        #expect(item.kind == .series)
        #expect(item.year == 2006)
        #expect(item.ratings.community == 8.9)
        #expect(PortalItemID(item.id)?.portal == "serieshub")
        #expect(PortalItemID(item.id)?.key == "serieshub:chalk-line:2006")
    }

    /// The foreign address is in `posterID` — the same agreement as with the provider
    /// catalog. Whoever wanted to build it would have nothing to build.
    /// AP84: the field was in the contract and was read, but never arrived at the title — the
    /// language corner on the poster would never have shown anything.
    @Test("The languages arrive at the title")
    func languagesArrive() {
        #expect(entry().asMediaItem(portal: "p").languages == ["DE", "EN"])
    }

    @Test("The image address is passed through, not built")
    func imageAddress() {
        let item = entry().asMediaItem(portal: "p")
        #expect(item.artwork.posterID == "https://beispiel.invalid/plakat.jpg")

        let source = PortalSource(bridge: PortalBridge(basis: URL(string: "http://x.invalid")!))
        let address = source.imageURL(itemID: item.artwork.posterID!, kind: .primary, width: 480, tag: nil)
        #expect(address?.absoluteString == "https://beispiel.invalid/plakat.jpg")
    }

    /// Seen from outside, a folder is nothing but another library: its address takes the
    /// place of the entry point. Without this path there would be nowhere to go from a
    /// folder row.
    @Test("A folder becomes the identifier of the next level")
    func folderBecomesLevel() throws {
        let folder = entry(kind: "ordner").asMediaItem(portal: "serieshub")
        let level = try #require(PortalSource.levelID(forItem: folder))
        let decomposed = try #require(PortalLibraryID(level))
        #expect(decomposed.portal == "serieshub")
        // The folder's address, unchanged — it is passed on and not interpreted.
        #expect(decomposed.entry == "f=showSeasons&sUrl=x")
    }

    /// **Only a folder leads deeper.** If the check on the kind were in the view instead of
    /// here, there would be two versions of the same decision — and a title in a mixed list
    /// ("Discover" shows series and headings side by side) would end up in a level instead of
    /// on its detail page.
    @Test("A title leads into no level, but to its page")
    func onlyFoldersLeadDeeper() {
        for kind in ["serie", "film", "staffel", "folge", "trenner"] {
            let item = entry(kind: kind).asMediaItem(portal: "p")
            #expect(PortalSource.levelID(forItem: item) == nil, "\(kind) should not lead deeper")
        }
        #expect(PortalSource.levelID(forItem: entry(kind: "ordner").asMediaItem(portal: "p")) != nil)
    }

    @Test("Without a state there is no progress — not zero percent")
    func withoutState() {
        let item = entry().asMediaItem(portal: "p")
        #expect(item.progress == nil)
        #expect(item.isFavorite == false)
    }

    @Test("With a state, bar and favorite mark come along")
    func withProgress() {
        let state = BridgeReply.State(
            portion: 0.25, remainingSeconds: 1800, positionSeconds: 600, seen: false, favorite: true)
        let item = entry(state: state, duration: 40).asMediaItem(portal: "p")
        #expect(item.progress?.position == 600)
        #expect(item.progress?.duration == 2400)
        #expect(item.isFavorite == true)
    }

    /// A reader often does not know an entry's duration. The bar must still be right anyway —
    /// it is carried in the fraction.
    @Test("Without a runtime the duration is calculated back from the fraction")
    func durationFromFraction() {
        let state = BridgeReply.State(
            portion: 0.25, remainingSeconds: 1800, positionSeconds: 600, seen: false, favorite: false)
        let item = entry(state: state, duration: nil).asMediaItem(portal: "p")
        #expect(item.progress?.duration == 2400)
    }

    @Test("The kinds of the bridge become the kinds of the app")
    func kinds() {
        #expect(entry(kind: "film").asMediaItem(portal: "p").kind == .movie)
        #expect(entry(kind: "staffel").asMediaItem(portal: "p").kind == .season)
        #expect(entry(kind: "folge").asMediaItem(portal: "p").kind == .episode)
        #expect(entry(kind: "serie").asMediaItem(portal: "p").kind == .series)

        // **A folder is not a title.** Until 2026-08-27 this was `.series`, and that was exactly
        // the bug noticed on the TV: "Popular series" are thirty genres, and they appeared as
        // posters.
        #expect(entry(kind: "ordner").asMediaItem(portal: "p").kind == .folder)
        // A subheading is not an entry at all.
        #expect(entry(kind: "trenner").asMediaItem(portal: "p").kind == .separator)
    }
}
