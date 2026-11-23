import Core
import Foundation
import ParentalControls
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **Continue Watching per profile and filtered** (AP58, finding K4, 2026-09-26). Until then the
/// history existed once per device, without approval, and a child profile saw what an adult
/// had started on the same phone.
@Suite("History per profile")
struct HistoryProfileTests {

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "history-\(UUID().uuidString)")
    }

    private func entry(
        _ identifier: String, origin: Catalog.Origin = .jellyfin,
        approval: HistoryClearance? = nil
    ) -> HistoryEntry {
        HistoryEntry(identifier: identifier, origin: origin, title: identifier, approval: approval)
    }

    private func history(_ entries: HistoryEntry...) -> History {
        var history = History()
        for entry in entries.reversed() { history.note(entry) }
        return history
    }

    // MARK: - Store

    @Test("Every profile has its own history")
    func perProfile() async {
        let location = folder()
        await ProfilePointer.als("adult") {
            await HistoryStore(folder: location).save(history(entry("film-16")))
        }
        let kind = await ProfilePointer.als("child") { await HistoryStore(folder: location).load() }
        let adult = await ProfilePointer.als("adult") {
            await HistoryStore(folder: location).load()
        }
        #expect(kind.entries.isEmpty)
        #expect(adult.entries.map(\.identifier) == ["film-16"])
    }

    @Test("The device catalog moves into the active profile once and nowhere else")
    func takeover() async throws {
        let location = folder()
        await ProfilePointer.als(nil) {
            await HistoryStore(folder: location).save(history(entry("old")))
        }
        let store = HistoryStore(folder: location)
        let first = await ProfilePointer.als("first") { await store.load() }
        let secondOne = await ProfilePointer.als("second") { await store.load() }

        #expect(first.entries.map(\.identifier) == ["old"])
        #expect(secondOne.entries.isEmpty, "no copy into a second profile")
        let device = try #require(await store.location(forItem: nil))
        #expect(!FileManager.default.fileExists(atPath: device.path))
        let reread = await ProfilePointer.als("first") {
            await HistoryStore(folder: location).load()
        }
        #expect(reread.entries.map(\.identifier) == ["old"], "survives a restart")
    }

    @Test("The approval survives the disk")
    func approvalOnDisk() async {
        let location = folder()
        let approval = HistoryClearance(
            ageRating: "FSK-6", series: "series-1", seriesClearance: "FSK-12",
            seriesClearanceChecked: true)
        await ProfilePointer.als("p") {
            await HistoryStore(folder: location).save(history(entry("f", approval: approval)))
        }
        let read = await ProfilePointer.als("p") { await HistoryStore(folder: location).load() }
        #expect(read.entries.first?.approval == approval)
    }

    // MARK: - Filter

    private let childWithPin = ProtectionRule(
        deviceLocked: false, accountKind: .kind, isPinSet: true, limit: .from12)
    private let childWithoutPin = ProtectionRule(
        deviceLocked: false, accountKind: .kind, isPinSet: false, limit: .from12)

    @Test("In child mode the age limit filters as on the TV")
    func ageLimit() {
        let rated16 = entry("film-16", approval: HistoryClearance(ageRating: "FSK-16"))
        let rated6 = entry("film-6", approval: HistoryClearance(ageRating: "FSK-6"))
        #expect(!childWithPin.shows(history: rated16))
        #expect(childWithPin.shows(history: rated6))
        #expect(ProtectionRule.pending.shows(history: rated16))
    }

    @Test("An episode without a looked-up series approval is blocked in child mode")
    func episodeWithoutSeriesApproval() {
        let pending = entry(
            "episode", approval: HistoryClearance(ageRating: "FSK-6", series: "series-1"))
        let verified = entry(
            "episode",
            approval: HistoryClearance(
                ageRating: "FSK-6", series: "series-1", seriesClearanceChecked: true))
        let seriesTooOld = entry(
            "episode",
            approval: HistoryClearance(
                ageRating: "FSK-6", series: "series-1", seriesClearance: "FSK-16",
                seriesClearanceChecked: true))
        #expect(!childWithPin.shows(history: pending))
        #expect(childWithPin.shows(history: verified))
        #expect(!childWithPin.shows(history: seriesTooOld))
    }

    @Test("An entry without approval is missing in child mode, not for adults")
    func withoutApproval() {
        let legacy = entry("old")
        #expect(!childWithPin.shows(history: legacy))
        #expect(!childWithoutPin.shows(history: legacy))
        #expect(ProtectionRule.pending.shows(history: legacy))
    }

    @Test("A channel with an approval note passes the age filter")
    func channel() {
        let channel = entry("ahorn", origin: .channelList, approval: HistoryClearance())
        #expect(childWithPin.shows(history: channel))
    }

    // MARK: - Wiring

    @Test("Home filters the history and receives the rule from the shell")
    func wired() throws {
        let start = try SourceText.read("StartModel.swift", in: .featuresPhone)
        #expect(start.contains(".filter(rule.shows(history:))"))
        let placeholder = try SourceText.read("TabPlaceholder.swift", in: .featuresPhone)
        #expect(placeholder.contains("rule: model.parentalControls.rule)\n    }"))
    }
}
