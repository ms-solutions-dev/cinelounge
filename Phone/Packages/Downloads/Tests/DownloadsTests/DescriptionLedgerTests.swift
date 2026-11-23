import Foundation
import Testing

@testable import Downloads

/// What lies next to the file — so that the downloads are more than a list without network.
///
/// **The product owner's requirement of 2026-09-09:** *"even if I only download 1 episode,
/// the navigation should be like this when I am in Downloads: poster →
/// detail view with downloaded episodes."* The check therefore covers not only that something
/// comes back, but that five episodes are **one** group and that deleting one
/// of them takes nothing away from the others.
@Suite("Description ledger")
struct DescriptionLedgerTests {

    private static func folder() throws -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// **Made of two pieces**, because `scripts/strings.py` takes `word.word` for a
    /// catalog key — the same caution as at ``DownloadLedger/stem``.
    private static let faceName = "p1" + ".jpg"

    private static func episode(_ number: Int, series: String = "morrowfeld") -> DownloadDescription {
        DownloadDescription(
            id: "\(series)-f\(number)", title: "Folge \(number)", beside: "S1 · F\(number)",
            series: series, seriesTitle: "Morrowfeld", season: 1, episode: number,
            ratings: ["imdb": "8,1"],
            poster: "plakat-morrowfeld.jpg", backdrop: "kopf-morrowfeld.jpg",
            cast: [.init(id: "p1", name: "Ilka Brandmoor", image: Self.faceName)],
            ratingShares: ["imdb": 0.81],
            episodeImage: "still-\(number).jpg")
    }

    @Test("What was filed comes back")
    func thereAndBack() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = DescriptionLedger(folder: folder)

        ledger.create(Self.episode(1))
        let back = ledger.description(zu: "morrowfeld-f1")
        #expect(back?.title == "Folge 1")
        #expect(back?.ratings["imdb"] == "8,1")
        #expect(back?.ratingShares["imdb"] == 0.81)
        #expect(back?.cast.first?.image == Self.faceName)
    }

    @Test("The same identifier replaces and does not pile up")
    func replaces() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = DescriptionLedger(folder: folder)

        ledger.create(Self.episode(1))
        ledger.create(Self.episode(1))
        #expect(ledger.read().count == 1)
    }

    /// **Five episodes are one poster.** Without the series identifier there would be five tiles on the
    /// downloads screen — exactly what the product owner does not want.
    @Test("Five episodes of a series make one group")
    func oneGroup() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = DescriptionLedger(folder: folder)

        for number in 1...5 { ledger.create(Self.episode(number)) }

        let groups = Set(ledger.read().map { $0.series ?? $0.id })
        #expect(groups.count == 1)
        #expect(ledger.read().count == 5)
    }

    /// **The case that ``DownloadDescription`` names explicitly in its DocC.**
    @Test("Deleting an episode does not take the poster from the series")
    func posterStays() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = DescriptionLedger(folder: folder)
        for number in 1...5 { ledger.create(Self.episode(number)) }

        let orphaned = ledger.remove("morrowfeld-f3")

        #expect(ledger.read().count == 4)
        #expect(!orphaned.contains("plakat-morrowfeld.jpg"))
        #expect(!orphaned.contains("kopf-morrowfeld.jpg"))
        #expect(!orphaned.contains(Self.faceName))
        // The episode image belongs only to this episode — it goes with it.
        #expect(orphaned == ["still-3.jpg"])
    }

    @Test("The last episode takes everything along")
    func lastTakesAll() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = DescriptionLedger(folder: folder)
        ledger.create(Self.episode(1))

        let orphaned = Set(ledger.remove("morrowfeld-f1"))

        #expect(
            orphaned
                == ["plakat-morrowfeld.jpg", "kopf-morrowfeld.jpg", Self.faceName, "still-1.jpg"])
        #expect(ledger.read().isEmpty)
    }

    @Test("An unknown identifier clears nothing")
    func unknown() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = DescriptionLedger(folder: folder)
        ledger.create(Self.episode(1))

        #expect(ledger.remove("gibt-es-nicht").isEmpty)
        #expect(ledger.read().count == 1)
    }

    /// **A description without images still holds.** A portal title often brings neither
    /// poster nor background; the page must then consist of text and not of
    /// an error.
    @Test("A description without images still works")
    func withoutImages() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = DescriptionLedger(folder: folder)

        ledger.create(DownloadDescription(id: "nackt", title: "Without anything"))

        let back = ledger.description(zu: "nackt")
        #expect(back?.title == "Without anything")
        #expect(back?.imageNames.isEmpty == true)
        #expect(ledger.remove("nackt").isEmpty)
    }

    /// **An older ledger stays readable.** The fields from 2026-09-09 were added later;
    /// a single old row must not make the whole list unreadable.
    @Test("A ledger without the new fields stays readable")
    func oldBook() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = """
            [{"id":"alt","titel":"Old entry","bewertungen":{},"gattungen":[],
            "besetzung":[],"gelegtAm":768000.0}]
            """
        try Data(old.utf8).write(
            to: folder.appendingPathComponent(DescriptionLedger.fileName))

        let ledger = DescriptionLedger(folder: folder)
        #expect(ledger.read().count == 1)
        #expect(ledger.description(zu: "alt")?.logo == nil)
        #expect(ledger.description(zu: "alt")?.ratingShares.isEmpty == true)
    }
}

/// The images that belong to a download.
@Suite("Download images")
struct DownloadImagesTests {

    private static func folder() throws -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// **The same address yields the same name** — that is why ten episodes share one
    /// poster and do not create ten files.
    @Test("The same address gives the same name")
    func sameName() {
        let a = URL(string: "https://server/Items/1/Images/Primary?tag=x")!
        #expect(DownloadImages.name(forItem: a) == DownloadImages.name(forItem: a))
        #expect(
            DownloadImages.name(forItem: a)
                != DownloadImages.name(forItem: URL(string: "https://server/Items/2")!))
    }

    /// **The server name is not in the file name** — the same rule as for the
    /// ``DesignSystemPhone/ImageStore``.
    @Test("The name does not reveal the server")
    func noTrace() {
        let name = DownloadImages.name(forItem: URL(string: "https://vault.example:8096/bild.jpg")!)
        #expect(!name.contains("vault"))
        #expect(name.hasSuffix(".jpg"))
    }

    @Test("What is already there is not fetched twice")
    func onlyOnce() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let counter = TallyCounter()
        let frames = DownloadImages(
            folder: folder,
            fetcher: { _ in
                await counter.one()
                return Data([0xFF, 0xD8])
            })
        let address = URL(string: "https://server/plakat.jpg")!
        let name = DownloadImages.name(forItem: address)

        #expect(await frames.fetch(address, under: name))
        #expect(await frames.fetch(address, under: name))

        #expect(await counter.state == 1)
        #expect(frames.isPresent(name))

        frames.remove([name])
        #expect(!frames.isPresent(name))
    }

    /// **A missing image holds nothing up.** The bytes are the main thing; the poster
    /// is the extra.
    @Test("A failure on fetching has no consequences")
    func failure() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        struct Aus: Error {}
        let frames = DownloadImages(folder: folder, fetcher: { _ in throw Aus() })
        let address = URL(string: "https://server/weg.jpg")!

        #expect(await frames.fetch(address, under: DownloadImages.name(forItem: address)) == false)
    }

    private actor TallyCounter {
        var state = 0
        func one() { state += 1 }
    }
}
