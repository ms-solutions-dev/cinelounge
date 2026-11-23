import Core
import Flows
import PlaylistKit
import PortalKit
import Testing

/// **The shape rules in `Core` against the readers of the two packages** (AP58 R6, St8).
///
/// ``Core/Origin`` reads identifiers as strings, because `Core` may know neither `PortalKit` nor
/// `PlaylistKit`. The readers there (`PortalItemID`, `XtreamVOD.Reference`,
/// `XtreamVODSource.parseLibraryID`, `PortalLibraryID`) are the truth about the shape.
/// This board keeps both together: if a package changes its identifier, it turns red here and
/// not first in the child profile.
struct OriginFormTests {

    /// Title identifiers from all three worlds, plus edge cases.
    static let title = [
        "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6",
        "", "nur|zwei", "|leer|vorn", "serieshub|s:chalk-line|scheme://x",
        "animehub|serie|morrowfeld", "a|b|c|d",
        "liste-1#movie#4711", "liste-1#series#22", "liste-1#episode#22#mkv",
        "movie#movie#1", "liste#movie#", "liste#film#3", "xtream#live#4711", "#movie#9",
        PortalItemID(portal: "p", key: "k", address: "a|b").identifier,
        XtreamVOD.Reference(playlistID: "l#x", role: .episode, id: "7", containerExtension: "mp4")
            .itemID,
    ]

    /// Library identifiers, plus the trap "portal search is literally called vod".
    static let libraries = [
        "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4", "liste-1|vod|4711", "liste-1|series|99",
        "|vod|1", "liste|vod|", PortalLibraryID(portal: "s", entry: "neu").identifier,
        PortalLibraryID(portal: "s", entry: "x|y", input: "such").identifier,
        "portal|suche|einstieg", "nur|zwei", "", "resume",
    ]

    @Test("Title: Core reads like PortalItemID and XtreamVOD.Reference", arguments: title)
    func titleForm(identifier: String) {
        let expected: Origin =
            PortalItemID(identifier) != nil
            ? .portals : XtreamVOD.Reference(itemID: identifier) != nil ? .provider : .jellyfin
        #expect(Origin.forItem(identifier: identifier) == expected)
    }

    @Test("Library: Core reads like parseLibraryID and PortalLibraryID", arguments: libraries)
    func libraryForm(identifier: String) {
        let expected: Origin =
            XtreamVODSource.parseLibraryID(identifier) != nil
            ? .provider : PortalLibraryID(identifier) != nil ? .portals : .jellyfin
        #expect(Origin.forItem(library: identifier) == expected)
    }

    /// **The narrow version lets only hex digits through** — the channel identifier that
    /// ``Origin/forItem(identifier:)`` assigns to the media server drops out here.
    @Test("The narrow media server check is narrower than the origin")
    func narrowVersion() {
        #expect(Origin.isMediaServerIdentifier("a1b2-c3d4"))
        #expect(!Origin.isMediaServerIdentifier(""))
        #expect(!Origin.isMediaServerIdentifier("xtream#live#4711"))
        #expect(Origin.forItem(identifier: "4711") == .jellyfin)
        #expect(Origin.isMediaServerIdentifier("4711"))
        #expect(!Origin.isMediaServerIdentifier("AHORN-HD"))
        #expect(Origin.forItem(identifier: "AHORN-HD") == .jellyfin)
    }

    /// **The failure interpretation no longer has an enumeration of its own.**
    @Test("The source of the disruption interpretation is the origin")
    func sourceIsOrigin() {
        let source: DisruptionInterpretation.Source = .provider
        #expect(source == Origin.provider)
    }
}
