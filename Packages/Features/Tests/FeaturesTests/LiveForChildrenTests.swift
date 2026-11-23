import Core
import Foundation
import ParentalControls
import PlaylistKit
import ProfileKit
import Testing

@testable import Features

/// **Live for children with an allow list** — AP52, product decision 14 of 2026-09-25.
///
/// Every check goes **through the connection**: the list is stored through the same
/// ``ParentalControlsState`` that Settings uses, and the rule that results is asked of the same
/// calculation that ``MainView`` asks on every path —
/// ``ParentalControls/ChildScope/channels(_:)`` for the Live area, overlay, favorites and jump,
/// ``ParentalControls/ChildScope/channelSelection(_:from:isVisible:)`` for the remote and the channel tile,
/// ``AppSidebar/mainDestinations(scope:hasPortals:)`` for the
/// bar, ``ChildGuard/target(afterDiscarding:surface:rule:)`` for the guard,
/// ``ShellModels/liveShelf(channels:surface:rule:)`` for the Live shelf.
@MainActor
@Suite("Live for children with an allow list")
struct LiveForChildrenTests {

    // MARK: - Setup

    /// A store over a book with exactly one profile of this kind — and, if given,
    /// with these groups on its allow list.
    private func state(
        kind: Profile.Kind, pin: Bool, groups: Set<ChannelApproval.Group>
    ) -> ParentalControlsState {
        let store = InMemoryStore()
        if pin { _ = Pin(store: store).set("1234") }
        let profileStore = InMemoryStore()
        var person = Profile(name: kind == .kind ? "Selin" : "Max")
        person.kind = kind
        var ledger = ProfileBook()
        ledger.create(person)
        ledger.write(in: profileStore)
        let state = ParentalControlsState(
            store: store,
            childAccounts: ChildAccountList(store: InMemoryStore()),
            profileStore: profileStore,
            childMode: ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!))
        if !groups.isEmpty {
            state.set(
                channelApproval: ChannelApproval(groups: groups), forItem: person.identifier.rawValue)
        }
        return state
    }

    nonisolated private static let children = ChannelApproval.Group(list: "l", name: "DE| Kinder")

    nonisolated private static func channel(
        _ id: String, group: String, list: String = "l", adult: Bool = false,
        epg: String? = nil
    ) -> Channel {
        Channel(
            id: id, name: id, streamURL: URL(string: "http://sender.example/\(id)")!,
            playlistID: list, group: group, epgID: epg, isAdult: adult)
    }

    /// A provider's catalog: two children's channels, news, an
    /// adult channel **in the children's group** and the same group in a second list.
    nonisolated private static let catalog: [Channel] = [
        channel("kimo", group: "DE| Kinder"),
        channel("kreisel", group: "DE| Kinder"),
        channel("nachrichten", group: "DE| News"),
        channel("nacht", group: "DE| Kinder", adult: true),
        channel("fremd", group: "DE| Kinder", list: "l2"),
    ]

    private let preferences = LivePreferences(showsAdultChannels: true)

    private func bar(_ state: ParentalControlsState) -> [AppSidebar.Destination] {
        AppSidebar.mainDestinations(scope: state.rule.scope, hasPortals: true)
    }

    // MARK: - Empty means no Live

    @Test("Empty list: no Live, no bar entry, no channel by any path")
    func emptyList() {
        let kind = state(kind: .kind, pin: true, groups: [])
        #expect(kind.rule.channelApproval.isEmpty)
        #expect(!kind.rule.scope.deliversChannels)
        #expect(bar(kind) == [.accounts, .search, .media, .favorites])
        #expect(kind.rule.scope.channels(Self.catalog).isEmpty)
        #expect(
            kind.rule.scope.channelSelection(
                "kimo", from: Self.catalog, isVisible: preferences) == nil)
        #expect(
            ChildGuard.target(afterDiscarding: .live, rule: kind.rule)
                == .media)
        #expect(!kind.rule.scope.isAllowed(.liveProvider("l")))
    }

    @Test("Empty list: even without a PIN a child gets no Live")
    func emptyListWithoutPin() {
        let kind = state(kind: .kind, pin: false, groups: [])
        #expect(!bar(kind).contains(.live))
        #expect(kind.rule.scope.channels(Self.catalog).isEmpty)
    }

    // MARK: - One group allowed

    @Test("Group \"Kinder\" allowed: bar with Live, without Sport")
    func groupOpensSidebar() {
        let kind = state(kind: .kind, pin: true, groups: [Self.children])
        #expect(bar(kind) == [.accounts, .search, .media, .live, .favorites])
        #expect(!bar(kind).contains(.sport), "the schedule knows no list")
        #expect(
            ChildGuard.target(afterDiscarding: .live, rule: kind.rule)
                == .live)
        // The redirect to the last selected provider must not intercept the guard.
        #expect(kind.rule.scope.isAllowed(.liveProvider("l")))
        #expect(!kind.rule.scope.isAllowed(AppSidebar.Destination.sport))
        #expect(!kind.rule.scope.isAllowed(.settings))
    }

    @Test("Group \"Kinder\" allowed: only its channels, on every path")
    func onlyTheAllowed() {
        let kind = state(kind: .kind, pin: true, groups: [Self.children])
        let seen = kind.rule.scope.channels(Self.catalog).map(\.id)
        #expect(seen == ["kimo", "kreisel"])
    }

    @Test("Group \"Kinder\" allowed: only its channels via the remote too")
    func remote() throws {
        let kind = state(kind: .kind, pin: true, groups: [Self.children])
        let choice = try #require(
            kind.rule.scope.channelSelection(
                "kimo", from: Self.catalog, isVisible: preferences))
        #expect(choice.channel.id == "kimo")
        #expect(choice.nachbarn.map(\.id) == ["kimo", "kreisel"], "Up/Down stays within the group")

        for locked in ["nachrichten", "nacht", "fremd"] {
            #expect(
                kind.rule.scope.channelSelection(
                    locked, from: Self.catalog, isVisible: preferences) == nil,
                "\(locked) does not play")
        }
    }

    @Test("The wrapper discards the paths when the list changes")
    func listChangesState() {
        let without = state(kind: .kind, pin: true, groups: [])
        let using = state(kind: .kind, pin: true, groups: [Self.children])
        let identifier = Profile(name: "Selin").identifier
        let old = ChildGuard.RuleState(active: identifier, surface: .kind, rule: without.rule)
        let fresh = ChildGuard.RuleState(active: identifier, surface: .kind, rule: using.rule)
        #expect(ChildGuard.discardsDestination(from: old, zu: fresh))
    }

    // MARK: - New groups, adult channels

    @Test("A new group from the provider does not appear")
    func newGroupStaysInvisible() {
        let kind = state(kind: .kind, pin: true, groups: [Self.children])
        let later = Self.catalog + [Self.channel("neu", group: "DE| Neu")]
        #expect(!kind.rule.scope.channels(later).map(\.id).contains("neu"))
        #expect(
            kind.rule.scope.channelSelection(
                "neu", from: later, isVisible: preferences) == nil)
        // It can be selected — but it is allowed only once someone ticks it.
        let rows = LivePermission.rows(
            choice: ChannelApproval.selectable(later), approval: kind.rule.channelApproval)
        let fresh = rows.first { $0.group.name == "DE| Neu" }
        #expect(fresh?.isAllowed == false)
    }

    @Test("An adult channel in an allowed group does not appear")
    func adultChannelStaysOut() {
        let kind = state(kind: .kind, pin: true, groups: [Self.children])
        #expect(!kind.rule.scope.channels(Self.catalog).map(\.id).contains("nacht"))
        // Not even with the device's adult switch turned on.
        #expect(
            kind.rule.scope.channelSelection(
                "nacht", from: Self.catalog, isVisible: LivePreferences(showsAdultChannels: true)) == nil)
        // And a group consisting only of adult channels cannot be selected at all.
        let nightOnly = [Self.channel("x", group: "FOR ADULTS", adult: true)]
        #expect(ChannelApproval.selectable(nightOnly).isEmpty)
        #expect(ChannelApproval.selectable(Self.catalog).first?.channels == 2, "Nacht does not count")
    }

    // MARK: - Adults

    @Test("Adults stay unchanged")
    func adultsUnchanged() throws {
        let large = state(kind: .adult, pin: true, groups: [])
        #expect(large.rule.scope.channels(Self.catalog) == Self.catalog)
        #expect(
            bar(large) == [
                // In the drawn order since 2026-09-30; "Update all services"
                // is back since 2026-10-01. (AP63).
                .accounts, .search, .media, .live, .sport, .vod, .portals, .favorites, .sync,
                .settings,
            ])
        let choice = try #require(
            large.rule.scope.channelSelection(
                "nachrichten", from: Self.catalog, isVisible: LivePreferences()))
        #expect(choice.nachbarn.map(\.id) == ["kimo", "kreisel", "nachrichten", "fremd"])
        #expect(
            ChildGuard.target(afterDiscarding: .sport, rule: large.rule)
                == .sport)
    }

    @Test("A device lock without a child profile still removes Live completely")
    func deviceLockWithoutChild() {
        let locked = ProtectionRule(deviceLocked: true, isPinSet: true)
        #expect(!locked.scope.deliversChannels)
        #expect(locked.scope.channels(Self.catalog).isEmpty)
    }

    // MARK: - The Home screen

    @Test("The Live shelf appears for a child only with a list")
    func homeWithList() async {
        func shelves(_ state: ParentalControlsState) async -> [String] {
            let model = HomeModel(
                source: ChildInterfaceTests.ChildSource(), rule: state.rule,
                surface: state.surface, store: InMemoryStore(),
                shelfStore: InMemoryStore(),
                liveShelf: { [MediaItem(id: "kimo", kind: .channel, title: "KiMO")] })
            await model.load()
            guard case .ready(_, let shelves) = model.state else { return [] }
            return shelves.map(\.id)
        }
        #expect(!(await shelves(state(kind: .kind, pin: true, groups: []))).contains(LiveShelf.identifier))
        #expect(
            (await shelves(state(kind: .kind, pin: true, groups: [Self.children])))
                .contains(LiveShelf.identifier))
    }

    /// **Channels in search, on the TV since 2026-09-26** (B4) — through the same filter
    /// as the bar, Live shelf and player: a child finds only the channels it is cleared for,
    /// no adult channel in the children's group and nothing from another list.
    @Test("The channel search filters like the Live section")
    func channelSearchFiltered() async {
        func match(_ rule: ProtectionRule) async -> [String] {
            let catalog = Self.catalog
            let source = SearchModel.channelSource(
                { catalog }, rule: rule, preferences: { LivePreferences(showsAdultChannels: true) })
            return (await source("kimo", 20)).match.map(\.id)
                + (await source("nacht", 20)).match.map(\.id)
                + (await source("fremd", 20)).match.map(\.id)
        }
        #expect(await match(.pending) == ["kimo", "nacht", "fremd"])
        #expect(await match(state(kind: .kind, pin: true, groups: [Self.children]).rule) == ["kimo"])
        #expect(await match(state(kind: .kind, pin: true, groups: []).rule).isEmpty)
    }

    /// **Recently watched channels in "Continue Watching", as on the phone** (C5, 2026-09-26) — and
    /// none for a child without channel clearance, because ``ParentalControls/ChildScope`` returns
    /// no channels there.
    @Test("\"Continue Watching\" carries the recently watched channels first, filtered")
    func continueWatchingWithChannels() async {
        func next(_ state: ParentalControlsState) async -> [String] {
            let model = HomeModel(
                source: ChildInterfaceTests.ChildSource(), rule: state.rule,
                surface: state.surface, store: InMemoryStore(),
                shelfStore: InMemoryStore(),
                recentChannels: { [MediaItem(id: "kimo", kind: .channel, title: "KiMO")] })
            await model.load()
            guard case .ready(_, let shelves) = model.state else { return [] }
            return shelves.first { $0.id == ShelfPreferences.resumeID }?.items.map(\.id) ?? []
        }
        #expect(await next(state(kind: .adult, pin: false, groups: [])).first == "kimo")
        #expect(!(await next(state(kind: .kind, pin: true, groups: []))).contains("kimo"))
    }

    @Test("The Live shelf shows the child only the allowed channels")
    func liveShelfFiltered() async {
        let downloads = LiveCache(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("cinelounge-livekind-\(UUID().uuidString)"))
        let listen = PlaylistStore(
            store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        listen.add(
            Playlist(id: "l", name: "Liste", kind: .m3u(URL(string: "http://liste.example")!)))
        let now = Date()
        let channels = [
            Self.channel("kimo", group: "DE| Kinder", epg: "kimo-epg"),
            Self.channel("nachrichten", group: "DE| News", epg: "news-epg"),
            Self.channel("nacht", group: "DE| Kinder", adult: true, epg: "nacht-epg"),
        ]
        await downloads.save(channels, for: "l")
        await downloads.save(
            programmes: channels.map {
                Programme(
                    id: $0.id, channelID: $0.epgID ?? "", title: "Jetzt",
                    start: now.addingTimeInterval(-600), end: now.addingTimeInterval(3600))
            })
        let library = LiveLibrary(store: listen, cache: downloads)

        let kind = state(kind: .kind, pin: true, groups: [Self.children])
        let tiles = await ShellModels.liveShelf(
            channels: library, surface: kind.surface, rule: kind.rule)()
        #expect(tiles.map(\.id) == ["kimo"])

        let large = state(kind: .adult, pin: true, groups: [])
        let all = await ShellModels.liveShelf(
            channels: library, surface: large.surface, rule: large.rule)()
        #expect(Set(all.map(\.id)).isSuperset(of: ["kimo", "nachrichten"]))
    }

    // MARK: - The setting

    @Test("The list belongs to the profile: set, read, clear — and the rule follows")
    func storeOnProfile() {
        let store = InMemoryStore()
        _ = Pin(store: store).set("1234")
        let profileStore = InMemoryStore()
        var kind = Profile(name: "Selin")
        kind.kind = .kind
        var ledger = ProfileBook()
        ledger.create(kind)
        ledger.write(in: profileStore)
        let state = ParentalControlsState(
            store: store,
            childAccounts: ChildAccountList(store: InMemoryStore()),
            profileStore: profileStore,
            childMode: ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!))
        let identifier = kind.identifier.rawValue

        state.set(channelApproval: ChannelApproval(groups: [Self.children]), forItem: identifier)
        #expect(state.channelApproval(forItem: identifier).contains(Self.children))
        #expect(state.rule.channelApproval.contains(Self.children))
        #expect(ChannelApproval.load(from: store, forItem: "jemand-anders").isEmpty)
        #expect(ChannelApproval.load(from: store, forItem: nil).isEmpty, "no device base")

        state.set(channelApproval: ChannelApproval(), forItem: identifier)
        #expect(state.rule.channelApproval.isEmpty)
        #expect(!state.rule.scope.deliversChannels)
    }

    @Test("A child's row says what applies")
    func rowValue() {
        #expect(
            LivePermission.value(ChannelApproval(), catalog: Self.catalog)
                == AppLanguageSetting.word("childLock.liveOff"))
        let value = LivePermission.value(ChannelApproval(groups: [Self.children]), catalog: Self.catalog)
        #expect(value.contains("2"), "two channels, the adult channel does not count")
    }

    @Test("Vanished groups stay in the list so they can be removed")
    func vanishedGroup() {
        let route = ChannelApproval.Group(list: "l", name: "DE| Alt")
        let rows = LivePermission.rows(
            choice: ChannelApproval.selectable(Self.catalog),
            approval: ChannelApproval(groups: [Self.children, route]))
        let last = rows.last
        #expect(last?.group == route)
        #expect(last?.channels == nil)
        #expect(LivePermission.hasMultipleLists(rows))
        #expect(LivePermission.blocks(rows).map(\.list) == ["l", "l2"])
    }
}
