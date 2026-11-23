import Core
import Foundation

/// **The truth table of child protection — both programs check against it** (AP58 R1).
///
/// Account type x device lock x device PIN x limit x allow list x title (origin, rating,
/// series rating open or known) x target → visible or locked.
///
/// **The answers here are written out and not computed from the rule.** They call neither
/// ``ProtectionRule`` nor ``ChildScope`` nor ``ApprovalInterpretation``; whoever changes one
/// of them sees the table turn red. That is why it lives in the package and not in a test
/// target: the tests of the TV and of the phone cannot include a foreign test target, this
/// package can. It is called only from tests.
///
/// **What it describes is the ownership line:** the scope (Live, portals, provider catalog,
/// sports, administration) always applies to a child, the age limit only with a PIN
/// (decision 20, AP45); an episode whose series rating is open is locked in child mode with a
/// limit (strand K); the allow list for channels applies only on a child profile.
public enum ChildProtectionBoard {

    /// The group that an allow list permits in the table.
    public static let group = ChannelApproval.Group(list: "tafel", name: "Kinder")

    // MARK: - The situations

    /// Who is sitting in front of it and what is set on the device.
    public struct Situation: Sendable, Hashable, CustomStringConvertible {
        /// Whether the profile is a child.
        public let kind: Bool
        public let deviceLocked: Bool
        public let pin: Bool
        /// The limit that applies — stored on the profile for a child, otherwise on the device.
        public let limit: AgeLimit?
        /// Whether the profile's allow list permits ``ChildProtectionBoard/group``.
        public let channelList: Bool

        public var description: String {
            "\(kind ? "child" : "adult"), device \(deviceLocked ? "locked" : "open"), "
                + "PIN \(pin ? "yes" : "no"), limit \(limit.map { String($0.rawValue) } ?? "none"), "
                + "list \(channelList ? "yes" : "no")"
        }

        /// The allow list as it is stored.
        public var approval: ChannelApproval {
            channelList ? ChannelApproval(groups: [ChildProtectionBoard.group]) : ChannelApproval()
        }

        /// Stores this situation in a store — PIN, limit and allow list. The profile itself (its
        /// type) and the device lock are stored by the platform, because their stores do not live
        /// in this package.
        public func create(in store: any KeyValueStore, profile: String) {
            if pin { _ = Pin(store: store).set("1234") }
            AgeLimit.write(limit, in: store, forItem: kind ? profile : nil)
            approval.save(to: store, forItem: profile)
        }

        /// The rule of this situation **via the shared rule builder** — for the package's tests.
        public var rule: ProtectionRule {
            let store = InMemoryStore()
            create(in: store, profile: "tafel")
            return RuleBuilder.rule(
                profile: "tafel", profileIsChild: kind, accountIsChild: false,
                deviceLocked: deviceLocked, from: store)
        }

        // MARK: Die ausgeschriebene Antwort

        var applies: Bool { pin && (deviceLocked || kind) }
        var childMode: Bool { kind || applies }
        var liveAllowed: Bool { !childMode || (kind && channelList) }

        /// Whether a rating passes the limit — written out, without ``ApprovalInterpretation``.
        func allows(_ raw: String?) -> Bool {
            guard applies, let limit else { return true }
            switch raw {
            case nil: return true
            case "FSK 6": return limit.rawValue >= 6
            case "FSK 16": return limit.rawValue >= 16
            default: return false
            }
        }
    }

    /// All situations: 2 x 2 x 2 x 2 x 2.
    public static var situations: [Situation] {
        var all: [Situation] = []
        for kind in [false, true] {
            for locked in [false, true] {
                for pin in [false, true] {
                    for limit in [nil, AgeLimit.from12] {
                        for list in [false, true] {
                            all.append(
                                Situation(
                                    kind: kind, deviceLocked: locked, pin: pin, limit: limit,
                                    channelList: list))
                        }
                    }
                }
            }
        }
        return all
    }

    // MARK: - The titles

    /// Where a title is asked about.
    public enum Target: String, Sendable, CaseIterable {
        /// In a list — Home, library, search; filtered via ``FilteredSource``.
        case list = "liste"
        /// A single title that is opened or played
        /// (``ChildScope/opens(_:origin:)``).
        case singleTitle = "einzeltitel"
        /// A stored title — download or history entry
        /// (``ProtectionRule/shows(approval:series:seriesClearance:verified:identifier:)``).
        case store = "ablage"
    }

    /// A title as a list delivers it — after the series rating has been looked up.
    ///
    /// The IDs follow the providers' formats (Xtream `list#movie#number`, portal
    /// `portal|key|address`, media server hex digits), so that a platform reads the origin
    /// from the ID as it does in operation.
    public struct Scenario: Sendable, CustomStringConvertible {
        public let name: String
        /// `jellyfin`, `provider`, `portals` or `channelList`.
        public let origin: String
        public let title: MediaItem

        public var description: String { name }

        /// `nil` for the media server, otherwise the name of the origin.
        public var originForScope: String? {
            origin == "medienserver" ? nil : origin
        }
    }

    private static func film(_ number: Int, _ name: String, _ approval: String?) -> Scenario {
        Scenario(
            name: name, origin: "medienserver",
            title: MediaItem(
                id: "0a1b2c3d\(number)", kind: .movie, title: name, ageRating: approval))
    }

    private static func episode(
        _ number: Int, _ name: String, own: String?, series: String?, verified: Bool
    ) -> Scenario {
        var title = MediaItem(
            id: "1b2c3d4e\(number)", kind: .episode, title: name,
            seriesID: "5e6f7a8b", ageRating: own ?? (verified ? series : nil))
        if own != nil { title.seriesClearance = series }
        title.seriesClearanceChecked = verified ? true : nil
        return Scenario(name: name, origin: "medienserver", title: title)
    }

    /// The titles of the table.
    public static let cases: [Scenario] = [
        film(1, "Film without rating", nil),
        film(2, "Film FSK 6", "FSK 6"),
        film(3, "Film FSK 16", "FSK 16"),
        film(4, "Film TV-MA (unrecognized)", "TV-MA"),
        episode(5, "Episode, series FSK 6", own: nil, series: "FSK 6", verified: true),
        episode(6, "Episode, series FSK 16", own: nil, series: "FSK 16", verified: true),
        episode(7, "Episode, series without rating", own: nil, series: nil, verified: true),
        episode(8, "Episode, series open", own: nil, series: nil, verified: false),
        episode(9, "Episode FSK 6 in series FSK 16", own: "FSK 6", series: "FSK 16", verified: true),
        episode(10, "Episode FSK 6, series open", own: "FSK 6", series: nil, verified: false),
        Scenario(
            name: "Provider title", origin: "anbieter",
            title: MediaItem(id: "tafel#movie#7", kind: .movie, title: "Provider title")),
        Scenario(
            name: "Portal title", origin: "portale",
            title: MediaItem(id: "beispiel|film|/film/8", kind: .movie, title: "Portal title")),
        Scenario(
            name: "Channel", origin: "senderliste",
            title: MediaItem(id: "sender-9", kind: .channel, title: "Channel")),
    ]

    /// **The written-out answer:** Is this title visible at this target in this situation?
    public static func isVisible(_ scenario: Scenario, _ target: Target, in state: Situation) -> Bool {
        switch scenario.origin {
        case "anbieter", "portale": return !state.childMode
        case "senderliste": return state.liveAllowed
        default: break
        }
        let title = scenario.title
        let withLimit = state.applies && state.limit != nil
        let underSeries = title.kind == .episode && title.seriesID != nil
        let pending = underSeries && title.seriesClearanceChecked != true
        let withoutOwn = (title.ageRating ?? "").isEmpty
        switch target {
        case .list, .singleTitle:
            if pending, withoutOwn { return !withLimit }
        case .store:
            if pending, withLimit { return false }
        }
        return state.allows(title.ageRating)
            && (title.seriesClearance == nil || state.allows(title.seriesClearance))
    }

    /// **The written-out answer for targets:** Does this situation reach the target?
    ///
    /// An adult reaches everything (what the lock takes away from them is taken away by bar and
    /// tabs); a child reaches only ``ChildTarget/forChildren`` and Live with its list.
    public static func reached(_ target: ChildTarget, in state: Situation) -> Bool {
        guard state.kind else { return true }
        switch target {
        case .mediaLibrary, .search, .favorites, .profileSwitch, .downloads, .player, .legalTexts:
            return true
        case .live: return state.channelList
        case .portals, .provider, .sport, .administration: return false
        }
    }

    /// The channel of the table — in ``group``.
    public static let channels = Channel(
        id: "sender-9", name: "Channel", streamURL: URL(string: "https://tafel.invalid/sender-9.m3u8")!,
        playlistID: group.list, group: group.name)

    /// A source that delivers exactly this one title **on every path** — list, Continue
    /// Watching, favourites, episodes, collections, similar titles, next episode, trailer and the
    /// single title. A platform that puts it behind its filter shows with it that none of the
    /// paths bypasses it.
    public struct Source: ContentSource {
        public let title: MediaItem

        public init(_ title: MediaItem) { self.title = title }

        public var displayName: String { "Tafel" }
        public nonisolated var canStartAtOffset: Bool { true }
        public nonisolated var tracksStateItself: Bool { true }

        public static let library = Library(id: "tafel", name: "Tafel", kind: .movies)

        public func libraries() async throws -> [Library] { [Self.library] }
        public func items(in library: Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
            [title]
        }
        public func item(id: String) async throws -> MediaItem { title }
        public func children(of itemID: String) async throws -> [MediaItem] { [title] }
        public func resumable(limit: Int) async throws -> [MediaItem] { [title] }
        public func collections() async throws -> [MediaItem] { [title] }
        public func favorites() async throws -> [MediaItem] { [title] }
        public func similarItems(to itemID: String, limit: Int) async throws -> [MediaItem] { [title] }
        public func episodes(of seriesID: String) async throws -> [MediaItem] { [title] }
        public func similarItem(to itemID: String) async throws -> MediaItem? { title }
        public func nextEpisode(after itemID: String) async throws -> MediaItem? { title }
        public func trailer(for itemID: String) async throws -> MediaItem? { title }
        public func segments(for itemID: String) async throws -> [MediaSegment] { [] }
        public func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            URL(string: "https://tafel.invalid/\(itemID)")!
        }
        public func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
        public func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
        public func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
        public func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    }

    // MARK: - The comparison

    /// What a platform answers differently from the table — empty means the same.
    ///
    /// - Parameter antwort: The platform's answer, `nil` for "does not ask here".
    public static func deviations(
        targets: [Target] = Target.allCases,
        isolation: isolated (any Actor)? = #isolation,
        _ reply: (Situation, Scenario, Target) async throws -> Bool?
    ) async rethrows -> [String] {
        var discoveries: [String] = []
        for state in situations {
            for scenario in cases {
                for target in targets {
                    guard let answer = try await reply(state, scenario, target) else { continue }
                    let expectedValue = isVisible(scenario, target, in: state)
                    if answer != expectedValue {
                        discoveries.append(
                            "\(state) · \(scenario) · \(target.rawValue): \(answer) instead of \(expectedValue)"
                        )
                    }
                }
            }
        }
        return discoveries
    }

    /// The same for targets.
    public static func deviations(_ reply: (Situation, ChildTarget) -> Bool?) -> [String] {
        var discoveries: [String] = []
        for state in situations {
            for target in ChildTarget.allCases {
                guard let answer = reply(state, target) else { continue }
                let expectedValue = reached(target, in: state)
                if answer != expectedValue {
                    discoveries.append("\(state) · \(target.rawValue): \(answer) instead of \(expectedValue)")
                }
            }
        }
        return discoveries
    }
}
