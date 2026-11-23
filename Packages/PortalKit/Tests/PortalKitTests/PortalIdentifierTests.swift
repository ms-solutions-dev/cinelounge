import Core
import Foundation
import Testing

@testable import PortalKit

/// The identifier carries three statements, and they must not fall apart.
@Suite("Portal identifiers")
struct PortalIdentifierTests {

    @Test("Back and forth gives the same")
    func roundTrip() {
        let identifier = PortalItemID(
            portal: "serieshub",
            key: "serieshub:chalk-line:2006",
            address: "f=showSeasons&sUrl=https%3A%2F%2Fserieshub.example%2Fserie%2Fchalk-line"
        )
        let back = PortalItemID(identifier.identifier)
        #expect(back == identifier)
    }

    /// The case on which a naive decomposition breaks.
    @Test("A separator in the address does not split wrongly")
    func separatorInAddress() {
        let identifier = PortalItemID(portal: "p", key: "p:titel:2020", address: "f=x&a=1|2|3")
        let back = PortalItemID(identifier.identifier)
        #expect(back?.address == "f=x&a=1|2|3")
        #expect(back?.portal == "p")
        #expect(back?.key == "p:titel:2020")
    }

    @Test("An empty key is allowed — a reader often gives no year")
    func emptyKey() {
        let back = PortalItemID("animehub||f=showEpisodes")
        #expect(back?.portal == "animehub")
        #expect(back?.key == "")
    }

    @Test("Nonsense is rejected instead of being half read")
    func nonsense() {
        #expect(PortalItemID("nur-ein-teil") == nil)
        #expect(PortalItemID("zwei|teile") == nil)
        #expect(PortalItemID("|leeres|portal") == nil)
    }

    @Test("The library identifier carries portal and entry point")
    func library() {
        let identifier = PortalLibraryID(portal: "serieshub", entry: "f=showNewEpisodes&sUrl=a%2Fb")
        let back = PortalLibraryID(identifier.identifier)
        #expect(back?.portal == "serieshub")
        #expect(back?.entry == "f=showNewEpisodes&sUrl=a%2Fb")
    }

    /// **The search term comes from the key and not from the address.** The address belongs to the portal script —
    /// `sName=` at Serieshub, `TVShowTitle=` at Animehub, nothing at all at the Ahorn. The key belongs to the
    /// bridge and looks the same everywhere.
    @Test("The key becomes the search term")
    func searchTermFromKey() {
        func searchTerm(_ identifier: String) -> String {
            PortalSource.searchTerm(for: PortalItemID(identifier)!)
        }
        #expect(searchTerm("serieshub|serieshub:morrowfeld:|f=showSeasons") == "morrowfeld")
        #expect(
            searchTerm("ahorn|ahorn:club-der-einsamen-herzen:|https://x")
                == "club der einsamen herzen")
        #expect(
            searchTerm("animehub|animehub:100-sleeping-princes-the-kingdom-of-dreams:|f=x")
                == "100 sleeping princes the kingdom of dreams")
    }

    /// **Without a key there is nothing to search** — a folder carries none, and an empty search term would ask
    /// a foreign portal for everything.
    @Test("A folder yields no search term")
    func folderYieldsNothing() {
        #expect(PortalSource.searchTerm(for: PortalItemID("serieshub||f=showAll")!) == "")
    }
}
