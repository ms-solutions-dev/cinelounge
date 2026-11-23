import Core
import Foundation
import Testing

@testable import ParentalControls

/// **The package against the truth table** (AP58 R1) — rule building, scope, filter and the
/// question for stored titles. TV and phone check their own paths against
/// the same table (`ChildProtectionBoardTVTests`, `ChildProtectionBoardPhoneTests`).
@Suite("Child protection: the truth table")
struct ChildProtectionBoardTests {

    /// The package's answer at every target.
    static func reply(
        _ state: ChildProtectionBoard.Situation, _ scenario: ChildProtectionBoard.Scenario,
        _ target: ChildProtectionBoard.Target
    ) async -> Bool {
        let rule = state.rule
        let scope = rule.scope
        if scenario.origin == "senderliste" {
            return scope.deliversChannels
                && !scope.channels([ChildProtectionBoard.channels]).isEmpty
        }
        switch target {
        case .list:
            guard scope.delivers(scenario.origin) else { return false }
            let source = rule.about(ChildProtectionBoard.Source(scenario.title))
            let list = (try? await source.items(in: "tafel", filter: .default)) ?? []
            return !list.isEmpty
        case .singleTitle:
            return scope.opens(scenario.title, origin: scenario.originForScope)
        case .store:
            let title = scenario.title
            return scope.delivers(scenario.origin)
                && rule.shows(
                    approval: title.ageRating, series: title.seriesID,
                    seriesClearance: title.seriesClearance, verified: title.seriesClearanceChecked)
        }
    }

    @Test("Every title at every target in every situation as in the board")
    func title() async {
        let discoveries = await ChildProtectionBoard.deviations { state, scenario, target in
            await Self.reply(state, scenario, target)
        }
        #expect(
            discoveries.isEmpty,
            "\(discoveries.count) Abweichungen:\n\(discoveries.prefix(20).joined(separator: "\n"))")
    }

    @Test("Every target in every situation as in the board")
    func targets() {
        let discoveries = ChildProtectionBoard.deviations { state, target in
            state.rule.scope.isAllowed(target)
        }
        #expect(discoveries.isEmpty, "\(discoveries.joined(separator: "\n"))")
    }

    /// The table itself — a few lines by hand, so that a table that moves together with the
    /// code is noticed.
    @Test("Anchor rows of the board")
    func anchor() throws {
        let childWithPin = ChildProtectionBoard.Situation(
            kind: true, deviceLocked: false, pin: true, limit: .from12, channelList: false)
        let childWithoutPin = ChildProtectionBoard.Situation(
            kind: true, deviceLocked: false, pin: false, limit: .from12, channelList: true)
        let adult = ChildProtectionBoard.Situation(
            kind: false, deviceLocked: false, pin: true, limit: .from12, channelList: false)
        let scenario = { (name: String) in
            try #require(ChildProtectionBoard.cases.first { $0.name == name })
        }
        #expect(!ChildProtectionBoard.isVisible(try scenario("Film FSK 16"), .list, in: childWithPin))
        #expect(ChildProtectionBoard.isVisible(try scenario("Film FSK 16"), .list, in: childWithoutPin))
        #expect(ChildProtectionBoard.isVisible(try scenario("Film FSK 16"), .list, in: adult))
        #expect(!ChildProtectionBoard.isVisible(try scenario("Portal title"), .list, in: childWithoutPin))
        #expect(ChildProtectionBoard.isVisible(try scenario("Channel"), .list, in: childWithoutPin))
        #expect(
            !ChildProtectionBoard.isVisible(try scenario("Episode, series open"), .list, in: childWithPin))
        #expect(
            ChildProtectionBoard.isVisible(
                try scenario("Episode FSK 6, series open"), .list, in: childWithPin))
        #expect(
            !ChildProtectionBoard.isVisible(
                try scenario("Episode FSK 6, series open"), .store, in: childWithPin))
        #expect(!ChildProtectionBoard.reached(.administration, in: childWithPin))
        #expect(ChildProtectionBoard.reached(.live, in: childWithoutPin))
        #expect(ChildProtectionBoard.reached(.administration, in: adult))
    }

    // MARK: - The filter is complete

    /// **No title-delivering path bypasses the wrapper** (finding K3). The source of the
    /// table delivers the same blocked title on every path.
    @Test("The filtered source filters every path, including collections, trailers and the single title")
    func complete() async throws {
        let rule = ProtectionRule(deviceLocked: false, accountKind: .kind, isPinSet: true, limit: .from6)
        let locked = MediaItem(id: "abc", kind: .movie, title: "18er", ageRating: "18")
        let source = rule.about(ChildProtectionBoard.Source(locked))
        #expect(source is FilteredSource)
        #expect(try await source.items(in: "tafel", filter: .default).isEmpty)
        #expect(try await source.children(of: "x").isEmpty)
        #expect(try await source.resumable(limit: 5).isEmpty)
        #expect(try await source.collections().isEmpty)
        #expect(try await source.favorites().isEmpty)
        #expect(try await source.similarItems(to: "x", limit: 5).isEmpty)
        #expect(try await source.episodes(of: "x").isEmpty)
        #expect(try await source.similarItem(to: "x") == nil)
        #expect(try await source.nextEpisode(after: "x") == nil)
        #expect(try await source.trailer(for: "x") == nil)
        await #expect(throws: ChildProtectionError.locked) { try await source.item(id: "abc") }
        #expect(try await source.itemCount(in: "tafel", filter: .default) == nil)
    }

    @Test("An approved title passes on every path, including the collections")
    func approvedPassesThrough() async throws {
        let rule = ProtectionRule(deviceLocked: false, accountKind: .kind, isPinSet: true, limit: .from12)
        let unrestricted = MediaItem(id: "abc", kind: .movie, title: "6er", ageRating: "6")
        let source = rule.about(ChildProtectionBoard.Source(unrestricted))
        #expect(try await source.collections() == [unrestricted])
        #expect(try await source.item(id: "abc") == unrestricted)
        #expect(try await source.trailer(for: "abc") == unrestricted)
    }

    @Test("Without an effective lock no wrapper")
    func withoutLockNoWrapper() {
        let source = ProtectionRule.pending.about(
            ChildProtectionBoard.Source(MediaItem(id: "a", kind: .movie, title: "a")))
        #expect(!(source is FilteredSource))
    }

    /// The rating of a series is the information that is filtered with — the wrapper passes
    /// it through, even for a blocked series.
    @Test("Series ratings pass unfiltered")
    func seriesApprovalsPass() async throws {
        let rule = ProtectionRule(deviceLocked: false, accountKind: .kind, isPinSet: true, limit: .from6)
        let series = MediaItem(id: "s1", kind: .series, title: "Serie", ageRating: "16")
        let source = rule.about(ChildProtectionBoard.Source(series))
        let reply = try await source.seriesApprovals(forItem: ["s1"])
        #expect(reply == [SeriesClearance(series: "s1", approval: "16")])
    }

    // MARK: - The rule builder

    /// **Same stores, same rule** — the missing equality check from finding K2.
    @Test("Both paths of the rule builder give the same rule")
    func ruleBuilderEqual() {
        for state in ChildProtectionBoard.situations {
            let store = InMemoryStore()
            state.create(in: store, profile: "p")
            let inOneGo = RuleBuilder.rule(
                profile: "p", profileIsChild: state.kind, accountIsChild: false,
                deviceLocked: state.deviceLocked, from: store)
            let separate = RuleBuilder.rule(
                device: .read(locked: state.deviceLocked, from: store),
                person: .read("p", isChild: state.kind, from: store), accountIsChild: false)
            #expect(inOneGo == separate, "\(state)")
        }
    }

    @Test("A child account of the old list makes the rule a child rule, even under an adult profile")
    func childAccount() {
        let rule = RuleBuilder.rule(
            profile: "p", profileIsChild: false, accountIsChild: true, deviceLocked: false,
            from: InMemoryStore())
        #expect(rule.accountKind == .kind)
        #expect(rule.scope.isInChildMode)
    }

    /// **The allow list only on the child** — the decision from R1 (fail-closed).
    @Test("The allow list of an adult profile does not apply")
    func listOnlyOnChild() {
        let store = InMemoryStore()
        ChannelApproval(groups: [ChildProtectionBoard.group]).save(to: store, forItem: "p")
        _ = Pin(store: store).set("1234")
        let rule = RuleBuilder.rule(
            profile: "p", profileIsChild: false, accountIsChild: false, deviceLocked: true,
            from: store)
        #expect(rule.channelApproval.isEmpty)
        #expect(!rule.scope.deliversChannels)
    }

    @Test("The limit is the stricter of profile and device, the profile's assignments win")
    func limitAndBoard() {
        let store = InMemoryStore()
        AgeLimit.write(.from16, in: store)
        AgeLimit.write(.from6, in: store, forItem: "p")
        UnrecognizedRatings(assignments: ["TV-MA": 18, "R": 16]).save(to: store)
        UnrecognizedRatings(assignments: ["R": 12]).save(to: store, forItem: "p")
        let rule = RuleBuilder.rule(
            profile: "p", profileIsChild: true, accountIsChild: false, deviceLocked: false,
            from: store)
        #expect(rule.limit == .from6)
        #expect(rule.assignments == ["TV-MA": 18, "R": 12])
    }

    // MARK: - The doors

    @Test("The door watcher: covered, request, opening, consuming")
    func doorGuard() {
        let rule = ProtectionRule(deviceLocked: true, isPinSet: true)
        let store = InMemoryStore()
        let pin = Pin(store: store)
        _ = pin.set("1234")
        var watcher = DoorGuard()
        #expect(watcher.isHidden("einstellungen", rule: rule))
        #expect(watcher.job(forItem: "einstellungen", rule: rule) != nil)
        let closedBefore = watcher.passesThrough("einstellungen", rule: rule)
        #expect(!closedBefore)
        let wrong = watcher.open("einstellungen", using: "0000", pin: pin)
        #expect(!wrong)
        let correct = watcher.open("einstellungen", using: "1234", pin: pin)
        #expect(correct)
        #expect(!watcher.isHidden("einstellungen", rule: rule))
        #expect(watcher.isHidden("konten", rule: rule), "the pass applies to one door")
        let finished = watcher.passesThrough("einstellungen", rule: rule)
        #expect(finished)
        #expect(watcher.isHidden("einstellungen", rule: rule), "and only once")
        let pending = watcher.passesThrough("einstellungen", rule: .pending)
        #expect(pending)
    }

    // MARK: - Live for children

    @Test("The allow list as rows: selectable first, vanished ones after")
    func livePermission() {
        let da = ChannelApproval.Group(list: "l", name: "Kinder")
        let route = ChannelApproval.Group(list: "l", name: "Alt")
        let rows = LivePermission.rows(
            choice: [ChannelApproval.Choice(group: da, channels: 3)],
            approval: ChannelApproval(groups: [route]))
        #expect(rows.map(\.group) == [da, route])
        #expect(rows.map(\.isAllowed) == [false, true])
        #expect(rows.map(\.channels) == [3, nil])
        #expect(!LivePermission.hasMultipleLists(rows))
    }
}
