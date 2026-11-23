import Core
import Downloads
import Foundation
import NetworkStatus
import ParentalControls
import ProfileKit
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **The child-safety leftovers from the check evening of 2026-09-25.**
///
/// * The next episode came unfiltered from the raw source.
/// * The downloads knew only one approval; since `Core` carries the series approval,
///   episode- **and** series approval must both pass, and an unknown series locks in child mode.
/// * An empty "active" in the profile ledger stays empty since the TV version; the phone finds
///   the signed-in account's profile again, through the latch.
@MainActor
@Suite("Child protection leftovers")
struct ChildProtectionRemainsTests {

    /// A child with limit "from 12" and an active lock.
    static let childRule = ProtectionRule(
        deviceLocked: true, accountKind: .kind, isPinSet: true, limit: .from12,
        blocksUnrecognized: true, assignments: [:])

    // MARK: - The next episode

    /// **The probe returns no playback URL**, so the open path only fails when the request
    /// is built — which is exactly what shows that the episode arrived there. The filtered path
    /// does not get that far.
    @Test("The next episode above the limit is not offered to a child")
    func nextEpisodeFiltered() async throws {
        let job = PlaybackJob(identifier: "free", origin: .jellyfin)
        let kind = SourceAssembly.playbackSource(
            ApprovalProbe(), width: 300, origin: .jellyfin, rule: Self.childRule)
        #expect(try await kind.nextEpisode(after: job) == nil)

        let pending = SourceAssembly.playbackSource(
            ApprovalProbe(), width: 300, origin: .jellyfin, rule: .pending)
        await #expect(throws: (any Error).self, "without a lock the episode reaches the request") {
            try await pending.nextEpisode(after: job)
        }
    }

    @Test("Every playback source of the switch goes through the filter")
    func playbackSourcesFiltered() throws {
        let setup = try SourceText.read("SourceAssembly.swift", in: .featuresPhone)
        #expect(!setup.contains("JellyfinSpielerquelle(quelle: $0"), "raw source in the player")
        #expect(setup.contains("JellyfinPlayerSource(source: rule.about(source)"))
    }

    // MARK: - Der Vorrat

    private static func items(_ identifier: String) -> DownloadJob {
        DownloadJob(
            id: .init(identifier), title: identifier, beside: nil, source: .jellyfin,
            extent: .film, tier: .low, estimatedSize: 1_000)
    }

    /// What remains in the downloads for a child.
    private static func isVisible(_ descriptions: [DownloadDescription]) -> [String] {
        let model = DownloadsModel(networkMonitor: NetworkWatch(), rule: childRule)
        model.set(
            downloads: Downloads(items: descriptions.map { items($0.id) }, isRunning: []),
            household: StorageBudget(items: [], unrestricted: 1_000_000), durations: [:], seen: [])
        model.set(descriptions: descriptions)
        return model.rows(forItem: .everything).map(\.title)
    }

    @Test("An episode whose looked-up series is under the limit stays")
    func episodeChecked() {
        let episode = DownloadDescription(
            id: "f", title: "f", series: "s", ageRating: "FSK 6", seriesClearanceChecked: true)
        #expect(Self.isVisible([episode]) == ["f"])
    }

    @Test("An episode without a looked-up series is blocked — also an old download")
    func episodeOpen() {
        let old = DownloadDescription(id: "old", title: "old", series: "s", ageRating: "FSK 6")
        let episodeOnly = DownloadDescription(
            id: "only", title: "only", series: "s", ageRating: "FSK 0",
            seriesClearanceChecked: false)
        #expect(Self.isVisible([old, episodeOnly]).isEmpty)
    }

    @Test("The episode's own approval and the series' approval must both pass")
    func bothApprovals() {
        let episode = DownloadDescription(
            id: "f", title: "f", series: "s", ageRating: "FSK 0",
            seriesClearance: "FSK 16", seriesClearanceChecked: true)
        #expect(Self.isVisible([episode]).isEmpty)
    }

    @Test("A film under the limit stays; without a lock everything stays")
    func movieAndOpen() {
        let film = DownloadDescription(id: "film", title: "film", ageRating: "FSK 0")
        #expect(Self.isVisible([film]) == ["film"])
        let old = DownloadDescription(id: "old", title: "old", series: "s", ageRating: "FSK 16")
        #expect(ProtectionRule.pending.shows(downloads: old))
    }

    @Test("Disk playback and the list ask the same filter")
    func sameFilter() throws {
        let switchPoint = try SourceText.read("CompositePlayerSource.swift", in: .featuresPhone)
        #expect(switchPoint.contains("rule.shows(downloads: downloads.description(job.identifier))"))
        let list = try SourceText.read("DownloadsModel.swift", in: .featuresPhone)
        #expect(list.contains("rule.shows(downloads: descriptions[identifier])"))
    }

    // MARK: - Niemand aktiv

    static let address = URL(string: "https://jellyfin.beispiel")!

    @Test("If nobody is active, the signed-in account's profile applies again")
    func nobodyActive() {
        let childProfile = Profile(
            identifier: .init(rawValue: "5E1A0000-0000-4000-8000-00000000C0DE"), name: "Selin",
            kind: .kind,
            credentials: [.jellyfin(server: Self.address, userID: "u-selin", username: "Selin")])
        let account = Account.Identifier(server: Self.address.absoluteString, user: "u-selin")
        let store = InMemoryStore()
        var ledger = ProfileBook()
        ledger.create(childProfile)
        ledger.clearActive()
        ledger.write(in: store)
        #expect(ProfileBook.read(from: store).active == nil)
        #expect(ProfileSwitch.restorable(account: account.stored, ledgerStore: store) == childProfile)
        #expect(ProfileSwitch.restorable(account: nil, ledgerStore: store) == nil)

        ledger.switchTo(zu: childProfile.identifier)
        ledger.write(in: store)
        #expect(ProfileSwitch.restorable(account: account.stored, ledgerStore: store) == nil)
    }

    @Test("The shell asks on every occasion and goes through the latch")
    func nobodyActiveWired() throws {
        let model = try SourceText.read("ShellModel.swift", in: .featuresPhone)
        for reason in [
            "public func start() {", "public func cloudArrived() {", "public func profileSwitched() {",
        ] {
            #expect(
                ChildProfilePhoneTests.bodyContent(reason, in: model)
                    .contains("restoreActiveProfile()"), "\(reason)")
        }
        let reconnectCount = ChildProfilePhoneTests.bodyContent(
            "private func restoreActiveProfile(", in: model)
        #expect(reconnectCount.contains("lock(account)"))
    }
}
