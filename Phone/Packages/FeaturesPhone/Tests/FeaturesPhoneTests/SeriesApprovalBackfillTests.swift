import Core
import Downloads
import Foundation
import ParentalControls
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **Old episode downloads get their series approval filled in later** — finding of
/// 2026-09-25. Without an answer from the server they stay locked in kids mode.
@MainActor
@Suite("Backfill series approvals in downloads")
struct SeriesApprovalBackfillTests {

    struct Mute: Error {}

    private static func ledger() throws -> DescriptionLedger {
        let location = FileManager.default.temporaryDirectory
            .appending(path: "backfill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        return DescriptionLedger(folder: location)
    }

    /// What was in the ledger before 2026-09-25: two episodes without a tag, a movie, a portal episode.
    private static func legacyCatalog(_ ledger: DescriptionLedger) {
        ledger.write([
            DownloadDescription(id: "alt", title: "alt", series: "s1", ageRating: "FSK 6"),
            DownloadDescription(id: "leer", title: "leer", series: "s2"),
            DownloadDescription(id: "film", title: "film", ageRating: "FSK 0"),
            DownloadDescription(
                id: "serieshub|morrowfeld-1-1|https://serieshub.example/redirect/1", title: "portal",
                series: "p"),
        ])
    }

    static let reply: SeriesClearances.Fetch = { allSeries in
        let known = ["s1": "FSK 16", "s2": "FSK 6"]
        return allSeries.compactMap { series in
            known[series].map { SeriesClearance(series: series, approval: $0) }
        }
    }

    @Test("With a reply it is backfilled, and the filter judges both approvals")
    func addedLater() async throws {
        let ledger = try Self.ledger()
        Self.legacyCatalog(ledger)
        let rule = ChildProtectionRemainsTests.childRule
        #expect(ledger.read().filter { rule.shows(downloads: $0) }.map(\.id) == ["film"])

        let count = await SeriesClearanceBackfill.backfill(
            in: ledger, approvals: SeriesClearances(), fetch: Self.reply)
        #expect(count == 2)

        let old = try #require(ledger.description(zu: "alt"))
        #expect(old.seriesClearanceChecked == true)
        #expect(old.ageRating == "FSK 6")
        #expect(old.seriesClearance == "FSK 16")
        let empty = try #require(ledger.description(zu: "leer"))
        #expect(empty.ageRating == "FSK 6")
        #expect(empty.seriesClearanceChecked == true)
        #expect(ledger.read().filter { rule.shows(downloads: $0) }.map(\.id).sorted() == ["film", "leer"])
        #expect(
            ledger.description(zu: "serieshub|morrowfeld-1-1|https://serieshub.example/redirect/1")?
                .seriesClearanceChecked
                == nil)
    }

    @Test("Without a reply everything stays locked")
    func offline() async throws {
        let ledger = try Self.ledger()
        Self.legacyCatalog(ledger)
        let count = await SeriesClearanceBackfill.backfill(
            in: ledger, approvals: SeriesClearances(), fetch: { _ in throw Mute() })
        #expect(count == 0)
        let rule = ChildProtectionRemainsTests.childRule
        #expect(ledger.read().filter { rule.shows(downloads: $0) }.map(\.id) == ["film"])
    }

    @Test("A second run asks nothing more")
    func once() async throws {
        let ledger = try Self.ledger()
        Self.legacyCatalog(ledger)
        let approvals = SeriesClearances()
        await SeriesClearanceBackfill.backfill(in: ledger, approvals: approvals, fetch: Self.reply)
        let second = await SeriesClearanceBackfill.backfill(
            in: ledger, approvals: approvals,
            fetch: { _ in
                Issue.record("asked"); return []
            })
        #expect(second == 0)
    }

    @Test("Start and network change trigger the backfill")
    func wired() throws {
        let model = try SourceText.read("ShellModel.swift", in: .featuresPhone)
        #expect(
            ChildProfilePhoneTests.bodyContent("public func start() {", in: model)
                .contains("downloads?.backfillSeriesClearances()"))
        let view = try SourceText.read("ShellView.swift", in: .featuresPhone)
        #expect(view.contains("model.downloads?.backfillSeriesClearances()"))
    }
}
