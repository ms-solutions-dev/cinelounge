import Core
import Foundation
import Testing

@testable import PortalKit

/// What an entry says about itself before a view draws it.
///
/// Both rules here were visible on the TV on 2026-08-27: a portal sends the title once more as the
/// description, and its images are wide while the app frames upright. Both belong to the entry and not in
/// the view — otherwise the next view inherits the defect again.
@Suite("Portals: what an entry says about itself")
struct PortalPresentationTests {

    private func entry(
        title: String = "Chalk Line",
        description: String? = "Ein Uhrmacher.",
        isImageWide: Bool? = nil
    ) -> BridgeReply.ContentEntryRecord {
        let raw = """
            {"titel":"\(title)","adresse":"f=showSeasons&sUrl=x","art":"serie",
             "jahr":2006,"beschreibung":\(description.map { "\"\($0)\"" } ?? "null"),
             "bild":"https://beispiel.invalid/plakat.jpg","sprachen":["DE"],
             "bewertung":null,"dauer_minuten":null,"nummer":null,
             \(isImageWide.map { "\"bild_breit\":\($0)," } ?? "")
             "hat_kinder":true,"schluessel":"p:chalk-line:2006","stand":null}
            """
        return try! JSONDecoder().decode(BridgeReply.ContentEntryRecord.self, from: Data(raw.utf8))
    }

    // MARK: - The subtitle

    /// **Viewer finding 2026-08-27:** for one portal `description` contains throughout the same text as `title`.
    /// In the list it thus stood twice one below the other — and because the detail page inherits the same
    /// field, a third time there.
    @Test("A description that only repeats the title is none")
    func subtitleDoesNotRepeatTitle() {
        let item = entry(title: "Beistourn Slusa", description: "Beistourn Slusa")
            .asMediaItem(portal: "p")
        #expect(item.overview == nil)
        // The title itself of course stays.
        #expect(item.title == "Beistourn Slusa")
    }

    /// Portals deliver the same title sometimes with trailing spaces, sometimes in capitals. A comparison for
    /// equality would miss that.
    @Test(
        "Margin and capitalization do not turn the repetition into information",
        arguments: ["  Chalk Line ", "CHALK LINE", "chalk line", "Chalk line  "]
    )
    func subtitleComparisonIsLenient(description: String) {
        let item = entry(description: description).asMediaItem(portal: "p")
        #expect(item.overview == nil)
    }

    @Test("An empty description is no description")
    func emptyDescription() {
        #expect(entry(description: "   ").asMediaItem(portal: "p").overview == nil)
        #expect(entry(description: nil).asMediaItem(portal: "p").overview == nil)
    }

    /// And the normal case stays untouched — otherwise the fix would have taken away more than the defect.
    @Test("A real description stays")
    func realDescriptionStays() {
        let item = entry(description: " Ein Uhrmacher. ").asMediaItem(portal: "p")
        // Without margin: the margin was cut off in the comparison, and what was compared should also be shown.
        #expect(item.overview == "Ein Uhrmacher.")
    }

    // MARK: - The image format

    /// Three states, not two: what the bridge does not say stays open — and the view falls back to portrait.
    @Test("The image format comes from the bridge, or stays open")
    func imageFormat() {
        #expect(entry(isImageWide: true).asMediaItem(portal: "p").artwork.isWide == true)
        #expect(entry(isImageWide: false).asMediaItem(portal: "p").artwork.isWide == false)
        #expect(entry(isImageWide: nil).asMediaItem(portal: "p").artwork.isWide == nil)
    }

    /// A level made up only of wide images is drawn wide; one about which nobody has said anything stays
    /// upright. The rule itself is in ``Core/MediaItem/prefersWideArtwork(in:)`` — here it is checked that the
    /// path from the bridge to there goes through.
    @Test("The level's format is derived from the bridge's field")
    func levelFormatArrives() {
        let wide = [entry(isImageWide: true), entry(isImageWide: true)]
            .map { $0.asMediaItem(portal: "p") }
        #expect(MediaItem.prefersWideArtwork(in: wide))

        let unchecked = [entry(), entry()].map { $0.asMediaItem(portal: "p") }
        #expect(!MediaItem.prefersWideArtwork(in: unchecked))
    }
}
