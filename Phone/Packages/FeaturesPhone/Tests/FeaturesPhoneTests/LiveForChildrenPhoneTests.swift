import Core
import Foundation
import ParentalControls
import PlaylistKit
import ProfileKit
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **Live for children on the phone, with allow list** — tvOS roadmap AP52,
/// product decision 14 of 2026-09-25. The counterpart to `LiveForChildrenTests` on the
/// TV.
///
/// Every check goes **through the connection**: The list is stored via the same
/// ``ParentalControlsState`` that ``ParentalControlsView`` uses, and the rule that
/// results asks the same places the wrapper asks —
/// ``ShellModel/tabs`` for the bar, ``SourceAssembly/filtered(_:rule:)`` for Live tabs,
/// Live shelf, favorites and search, ``SourceAssembly/blockedOrigins(_:)`` with
/// ``ChannelPlayerSource`` for the player.
@MainActor
@Suite("AP52 · Live for children on the phone")
struct LiveForChildrenPhoneTests {

    // MARK: - Setup

    let childProfile: Profile = {
        var person = Profile(name: "Child")
        person.kind = .kind
        return person
    }()

    /// A state over a ledger with exactly this profile — and, if named, with these
    /// groups on its allow list. Set **via the state**, as in
    /// Settings.
    private func makeState(
        _ person: Profile, pin: Bool, groups: Set<ChannelApproval.Group>
    ) -> ParentalControlsState {
        let keychain = InMemoryStore()
        if pin { _ = Pin(store: keychain).set("1234") }
        let ledger = InMemoryStore()
        var profileLedger = ProfileBook()
        profileLedger.create(person)
        profileLedger.write(in: ledger)
        let parentalState = ParentalControlsState(
            store: UserDefaults(suiteName: UUID().uuidString)!, keychain: keychain,
            ledgerStore: ledger)
        if !groups.isEmpty {
            parentalState.set(
                channelApproval: ChannelApproval(groups: groups), forItem: person.identifier.rawValue)
        }
        return parentalState
    }

    nonisolated static let children = ChannelApproval.Group(list: "l", name: "DE| Kinder")

    nonisolated static func channel(
        _ id: String, group: String, list: String = "l", adult: Bool = false,
        favorite: Bool = false
    ) -> Channel {
        Channel(
            id: id, name: id, streamURL: URL(string: "http://channel.example/\(id)")!,
            playlistID: list, group: group, isFavorite: favorite, isAdult: adult)
    }

    /// Two children's channels, news, an adult channel **in the children's group** and
    /// the same group in a second list. All remembered as favorite.
    nonisolated static let catalog: [Channel] = [
        channel("kimo", group: "DE| Kinder", favorite: true),
        channel("kreisel", group: "DE| Kinder", favorite: true),
        channel("nachrichten", group: "DE| News", favorite: true),
        channel("nacht", group: "DE| Kinder", adult: true, favorite: true),
        channel("fremd", group: "DE| Kinder", list: "l2", favorite: true),
    ]

    struct ProbeSource: ChannelListingSource {
        let channels: [Channel]
        func channels() async -> ChannelCatalog { ChannelCatalog(channels: channels) }
        func program(forItem channels: [Channel]) async -> [String: [Programme]] { [:] }
        func freshProgramme() async -> Int { 0 }
        func downloadsState() async -> ProgrammeState { .empty }
        func sport(from: Date, until: Date) async -> [SportEvent] { [] }
    }

    let state = CatalogState.fromAccesses(jellyfin: true, channelList: true, portals: true)

    /// What a child gets to see by this path.
    private func visibleIDs(
        _ rule: ProtectionRule, from catalog: [Channel] = catalog
    ) async
        -> [String]?
    {
        guard let source = SourceAssembly.filtered(ProbeSource(channels: catalog), rule: rule)
        else { return nil }
        return await source.channels().channels.map(\.id)
    }

    // MARK: - Empty means no Live

    @Test("Empty list: no Live tab, no channel source, the player blocks channels")
    func emptyList() async {
        await ProfilePointer.als(childProfile.identifier.rawValue) {
            let child = makeState(childProfile, pin: true, groups: [])
            let rule = child.rule
            #expect(rule.applies)
            #expect(rule.channelApproval.isEmpty)
            #expect(!ShellModel(catalogs: state, parentalControls: child).tabs.contains(.live))
            #expect(await visibleIDs(rule) == nil)
            #expect(SourceAssembly.blockedOrigins(rule).contains(.channelList))
        }
    }

    // MARK: - One group allowed

    @Test("Group \"Kinder\" allowed: the Live tab returns, portals stay away")
    func groupOpensSidebar() {
        ProfilePointer.als(childProfile.identifier.rawValue) {
            let child = makeState(childProfile, pin: true, groups: [Self.children])
            let tabs = ShellModel(catalogs: state, parentalControls: child).tabs
            #expect(tabs.contains(.live))
            #expect(!tabs.contains(.portals))
            #expect(!SourceAssembly.blockedOrigins(child.rule).contains(.channelList))
            #expect(SourceAssembly.blockedOrigins(child.rule).contains(.portals))
        }
    }

    @Test("Group \"Kinder\" allowed: only its channels — Live, Favorites, Search")
    func onlyTheAllowed() async throws {
        try await ProfilePointer.als(childProfile.identifier.rawValue) {
            let rule = makeState(childProfile, pin: true, groups: [Self.children]).rule
            #expect(await visibleIDs(rule) == ["kimo", "kreisel"])

            let source = try #require(
                SourceAssembly.filtered(ProbeSource(channels: Self.catalog), rule: rule))
            let favorites = await ChannelFavorites(source: source).favorites()
            #expect(favorites.title.map(\.id) == ["kimo", "kreisel"])

            let search = ChannelSearchSource(source: source, preferences: { LivePreferences() })
            #expect(await search.match(zu: "nachrichten", atMost: 10).match.isEmpty)
            #expect(await search.match(zu: "nacht", atMost: 10).match.isEmpty)
            #expect(await search.match(zu: "kimo", atMost: 10).match.count == 1)

            #expect(await source.sport(from: .distantPast, until: .distantFuture).isEmpty)
        }
    }

    @Test("Group \"Kinder\" allowed: the player plays only its channels")
    func playerSource() async throws {
        try await ProfilePointer.als(childProfile.identifier.rawValue) {
            let rule = makeState(childProfile, pin: true, groups: [Self.children]).rule
            let source = try #require(
                SourceAssembly.filtered(ProbeSource(channels: Self.catalog), rule: rule))
            let switchPoint = CompositePlayerSource(
                channels: ChannelPlayerSource(source: source),
                locked: SourceAssembly.blockedOrigins(rule), rule: rule)

            let isAllowed = try await switchPoint.target(
                zu: PlaybackJob(identifier: "kimo", origin: .channelList))
            #expect(isAllowed.identifier == "kimo")
            for locked in ["nachrichten", "nacht", "fremd"] {
                await #expect(throws: (any Error).self, "\(locked) does not play") {
                    _ = try await switchPoint.target(
                        zu: PlaybackJob(identifier: locked, origin: .channelList))
                }
            }
        }
    }

    // MARK: - New groups, adult channels

    @Test("A new provider group does not appear")
    func newGroupStaysInvisible() async {
        await ProfilePointer.als(childProfile.identifier.rawValue) {
            let child = makeState(childProfile, pin: true, groups: [Self.children])
            let later = Self.catalog + [Self.channel("neu", group: "DE| Neu")]
            #expect(await visibleIDs(child.rule, from: later) == ["kimo", "kreisel"])
            // It is selectable — allowed only once someone ticks it.
            let rows = LivePermission.rows(
                choice: ChannelApproval.selectable(later),
                approval: child.channelApproval(forItem: childProfile.identifier.rawValue))
            #expect(rows.first { $0.group.name == "DE| Neu" }?.isAllowed == false)
        }
    }

    @Test("An adult channel in an allowed group does not appear")
    func adultChannelStaysOut() async {
        await ProfilePointer.als(childProfile.identifier.rawValue) {
            let child = makeState(childProfile, pin: true, groups: [Self.children])
            // Also with the device's adult switch turned on.
            child.set(showsAdult: true)
            #expect(await visibleIDs(child.rule)?.contains("nacht") == false)
            let nightOnly = [Self.channel("x", group: "FOR ADULTS", adult: true)]
            #expect(ChannelApproval.selectable(nightOnly).isEmpty)
        }
    }

    // MARK: - Adults

    @Test("Adults stay unchanged")
    func adultsUnchanged() async {
        let adultProfile = Profile(name: "Adult")
        await ProfilePointer.als(adultProfile.identifier.rawValue) {
            let adultState = makeState(adultProfile, pin: true, groups: [])
            #expect(!adultState.rule.applies)
            #expect(await visibleIDs(adultState.rule) == Self.catalog.map(\.id))
            #expect(ShellModel(catalogs: state, parentalControls: adultState).tabs.contains(.live))
        }
    }

    @Test("A list on an adult profile opens nothing under the device lock")
    func listOnlyForChildren() async {
        let adultProfile = Profile(name: "Adult")
        await ProfilePointer.als(adultProfile.identifier.rawValue) {
            let adultState = makeState(adultProfile, pin: true, groups: [Self.children])
            adultState.mode.set(true)
            #expect(adultState.rule.applies, "the device lock applies")
            #expect(adultState.rule.channelApproval.isEmpty, "the list only applies to children")
            #expect(await visibleIDs(adultState.rule) == nil)
        }
    }

    // MARK: - The setting

    @Test("The list lives on the profile: set, read, clear — and the rule follows")
    func storeOnProfile() async {
        await ProfilePointer.als(childProfile.identifier.rawValue) {
            let child = makeState(childProfile, pin: true, groups: [])
            let identifier = childProfile.identifier.rawValue
            child.set(channelApproval: ChannelApproval(groups: [Self.children]), forItem: identifier)
            #expect(child.channelApproval(forItem: identifier).contains(Self.children))
            #expect(child.rule.channelApproval.contains(Self.children))
            #expect(child.channelApproval(forItem: "someone-else").isEmpty)

            child.set(channelApproval: ChannelApproval(), forItem: identifier)
            #expect(child.rule.channelApproval.isEmpty)
            #expect(await visibleIDs(child.rule) == nil)
        }
    }

    @Test("A child's row says what applies")
    func rowValue() {
        #expect(
            LivePermission.value(ChannelApproval(), catalog: Self.catalog)
                == AppLanguageSetting.word("childLock.liveOff"))
        let value = LivePermission.value(ChannelApproval(groups: [Self.children]), catalog: Self.catalog)
        #expect(value.contains("2"), "two channels, the adult channel does not count")
    }

    @Test("Vanished groups stay in the list so that they can be removed")
    func vanishedGroup() {
        let route = ChannelApproval.Group(list: "l", name: "DE| Alt")
        let rows = LivePermission.rows(
            choice: ChannelApproval.selectable(Self.catalog),
            approval: ChannelApproval(groups: [Self.children, route]))
        #expect(rows.last?.group == route)
        #expect(rows.last?.channels == nil)
        #expect(LivePermission.hasMultipleLists(rows))
        #expect(LivePermission.blocks(rows).map(\.list) == ["l", "l2"])
    }

    // MARK: - The wiring in the shell

    /// **The filters above only help if every channel path takes them.** A
    /// `unfilteredChannelSource()` on a path where viewing happens would be the gap.
    @Test("Every channel route to watching goes through the filter")
    func routesFiltered() throws {
        func code(_ name: String) throws -> String {
            try SourceText.read(name, in: .featuresPhone)
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        /// The next characters after each occurrence.
        func callCount(_ character: String, in text: String, length: Int) -> [Substring] {
            text.ranges(of: character).map { text[$0.lowerBound...].prefix(length) }
        }
        let placeholder = try code("TabPlaceholder.swift")
        let live = callCount("LiveView(", in: placeholder, length: 200)
        #expect(live.count == 1)
        #expect(
            live.allSatisfy {
                $0.contains("source: SourceAssembly.channelSource(rule: model.parentalControls.rule)")
            })
        let playerCalls = callCount("PlayerView(", in: placeholder, length: 1200)
        #expect(playerCalls.count == 1)
        #expect(
            playerCalls.allSatisfy {
                $0.contains("channelSource: SourceAssembly.channelSource(rule: model.parentalControls.rule)")
            })

        let setup = try code("SourceAssembly.swift")
        // Home, search, favorites and player: the filtered one everywhere.
        #expect(setup.components(separatedBy: "channelSource(rule: rule)").count - 1 == 4)
        // The unfiltered one only at its own place and in the filter itself.
        let live2 = try code("LiveView.swift")
        #expect(!live2.contains("SourceAssembly.channelSource"))
    }
}
