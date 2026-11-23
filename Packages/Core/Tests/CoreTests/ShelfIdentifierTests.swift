import Foundation
import Testing

@testable import Core

/// **One shelf identifier for both programs** (AP58 R6, St1).
///
/// The same `shelves.json` serves TV and phone. Until 2026-09-26 the two named a
/// library shelf differently — `a1b2…` here, `fresh:jellyfin:movies:a1b2…` there.
/// These checks pin down the adoption: old phone identifiers become the library's
/// identifier on reading, and what is already right stays.
@Suite("Shelf identifier and its adoption")
struct ShelfIdentifierTests {

    @Test("Old phone identifiers become the library identifier")
    func phonePrefix() {
        #expect(ShelfIdentifier.read("neu:medienserver:movies:a1b2c3") == "a1b2c3")
        #expect(ShelfIdentifier.read("neu:anbieter:movies:liste-1|vod") == "liste-1|vod")
        #expect(
            ShelfIdentifier.read("neu:portale:portalLevel:animehub||neu:folgen")
                == "animehub||neu:folgen")
        #expect(ShelfIdentifier.read("weiterSchauen") == "resume")
        #expect(ShelfIdentifier.read("heuteLive") == "live")
        #expect(ShelfIdentifier.read("ausDenPortalen") == "portale")
    }

    @Test("What is already correct or unknown stays")
    func remains() {
        for raw in [
            "resume", "a1b2c3", "liste-1|vod|4711", "animehub||neu", "neu:jellyfin:filme:42",
            "neu:medienserver:movies:", "zuletztHinzugefuegt",
        ] {
            #expect(ShelfIdentifier.read(raw) == raw)
        }
    }

    @Test("A half-adopted list does not get duplicates")
    func withoutDuplicate() {
        #expect(
            ShelfIdentifier.read(["resume", "neu:medienserver:movies:a1", "a1", "weiterSchauen"])
                == ["resume", "a1"])
    }

    @Test("A portal folder is recognized by its shape, a fixed shelf is not")
    func portalFolders() {
        #expect(ShelfIdentifier.isPortalFolder("animehub||neu"))
        #expect(!ShelfIdentifier.isPortalFolder("portale"))
        #expect(!ShelfIdentifier.isPortalFolder("liste-1|vod|4711"))
        #expect(!ShelfIdentifier.isPortalFolder("a1b2c3"))
    }

    /// **The file that a phone wrote before AP58 R6 is now read the same by every side.**
    @Test("The shelf order adopts while reading")
    func orderTakesOver() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-identifier-\(UUID().uuidString)")
        let store = FileStore(folder: folder)
        try store.set(
            """
            {"reihenfolge":["weiterSchauen","neu:medienserver:movies:f1","live"],\
            "ausgeblendet":["neu:medienserver:series:s1"],\
            "heldenregale":["neu:medienserver:movies:f1"]}
            """, for: ShelfOrder.key)

        let read = ShelfOrder.read(from: store)
        #expect(read.order == ["resume", "f1", "live"])
        #expect(read.hidden == ["s1"])
        #expect(read.heroShelves == ["f1"])

        let preferences = ShelfPreferences.load(from: store, forItem: nil)
        #expect(preferences.arrange(["s1", "f1", "resume", "live"]) == ["resume", "f1", "live"])
    }

    /// **Per profile** — whoever re-sorts no longer sorts for everyone on the device.
    @Test("The order of one profile leaves the device and other profiles alone")
    func perProfile() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-identifier-\(UUID().uuidString)")
        let store = FileStore(folder: folder)
        ShelfPreferences(order: ["live", "resume"]).save(to: store, forItem: "anna")

        #expect(ShelfPreferences.load(from: store, forItem: "anna").order == ["live", "resume"])
        #expect(ShelfPreferences.load(from: store, forItem: nil).order.isEmpty)
        #expect(ShelfPreferences.load(from: store, forItem: "ben").order.isEmpty)
        ProfilePointer.als("anna") {
            #expect(
                ShelfPreferences.load(from: store, forItem: ProfilePointer.active).order == [
                    "live", "resume",
                ])
        }
    }

    @Test("An order handed over from the phone names the libraries")
    func handoff() {
        var preferences = ShelfPreferences()
        preferences.adopt(order: ["resume", "neu:medienserver:movies:f1"])
        #expect(preferences.order == ["resume", "f1"])
    }

    /// 29.09.2026: Kategorien einer abgeleiteten Listenkennung fielen durch.
    @Test("Register shelf also for list identifiers with dashes")
    func registerShelfDerived() {
        #expect(
            ShelfIdentifier.registerShelf(zu: "xtream|iptvhost.example|maxdoe|vod|373")
                == "xtream|iptvhost.example|maxdoe|vod")
        #expect(
            ShelfIdentifier.registerShelf(zu: "xtream|iptvhost.example|maxdoe|series|216")
                == "xtream|iptvhost.example|maxdoe|series")
        #expect(ShelfIdentifier.registerShelf(zu: "liste|vod|4711") == "liste|vod")
        #expect(ShelfIdentifier.registerShelf(zu: "liste|vod|") == nil)
    }
}
