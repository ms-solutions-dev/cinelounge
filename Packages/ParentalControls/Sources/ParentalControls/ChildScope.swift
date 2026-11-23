import Core
import Foundation

/// What a child **reaches** — platform-neutral (AP58 R1, finding K1).
///
/// The TV maps it onto the targets of its bar, the phone onto its views. What is shared is
/// **which** targets exist, not how to reach them: focus, bar and signposts remain the
/// platform's business.
public enum ChildTarget: String, Sendable, Hashable, CaseIterable {
    case mediaLibrary = "mediathek"
    case search = "suche"
    case favorites = "favoriten"
    /// The way out: "Switch profile" — for parents the way in.
    case profileSwitch = "profilwechsel"
    case live
    case portals = "portale"
    /// The movie and series catalog of a channel provider.
    case provider = "anbieter"
    case sport
    /// The phone's downloads.
    case downloads = "vorrat"
    case player = "spieler"
    /// About, privacy, licences.
    case legalTexts = "rechtstexte"
    /// Settings, profiles, accounts, sync, parental controls — everything that manages a
    /// household.
    case administration = "verwaltung"

    /// What a child **always** reaches. Live is added with an allow list
    /// (``ChildScope/isAllowed(_:)``); portals, provider catalog, sports and administration
    /// never.
    public static let forChildren: Set<ChildTarget> = [
        .mediaLibrary, .search, .favorites, .profileSwitch, .downloads, .player, .legalTexts,
    ]
}

/// **The scope for children — one version for both programs** (AP58 R1, finding K1).
///
/// Until now child mode existed three times, and differently each time: on the TV
/// `profile.kind == .kind || applies`, on the phone `accountKind == .kind || applies`, and in
/// ``ProtectionRule`` a dead third version with `applies` alone. **This one is the one**,
/// and it takes the account type of the rule — which on the TV carries profile type **or**
/// child account, on the phone likewise. The narrower answer wins: a child account of the old
/// list is in child mode even under an adult profile.
///
/// **The scope is a selection, not a lock.** That is why it applies to a child even without
/// a PIN: channels and portals carry no age information, and a UI for children that showed
/// them because no PIN happens to be set would not be one. The **age limit**, by contrast,
/// stays tied to the PIN (``ProtectionRule/shows(_:)``) — without a PIN there would be no
/// way back through a locked door.
///
/// **Whoever rebuilds the scope elsewhere builds the gap back in.** The table
/// ``ChildProtectionBoard`` describes every answer of this type; both programs check against
/// it.
public struct ChildScope: Sendable, Hashable {

    public let rule: ProtectionRule

    public init(_ rule: ProtectionRule) {
        self.rule = rule
    }

    /// Whether the areas without ratings drop out — **always for a child**, otherwise only when
    /// the lock is in effect.
    public var isInChildMode: Bool {
        rule.accountKind == .kind || rule.applies
    }

    /// Whether administration is **missing** — for every child, with and without a device PIN
    /// (decision 20). Parents get in through the profile switch with their profile PIN.
    ///
    /// **An adult with a device lock keeps their doors** (``LockedDoors``): what counts is
    /// the type, not ``ProtectionRule/applies``.
    public var withoutManagement: Bool {
        rule.accountKind == .kind
    }

    /// Whether the channel list may deliver — in child mode only with an allow list that
    /// permits something, and then only its channels (``channels(_:)``).
    public var deliversChannels: Bool {
        TabScope.deliversChannels(isInChildMode: isInChildMode, channelApproval: rule.channelApproval)
    }

    /// Whether this origin may contribute titles or channels.
    ///
    /// - Parameter herkunft: `jellyfin`, `channelList`, `provider`, `portals`,
    ///   `downloads` — the names from ``TabScope/withoutApprovals``.
    public func delivers(_ origin: String) -> Bool {
        if origin == "senderliste" { return deliversChannels }
        return TabScope.delivers(origin, isInChildMode: isInChildMode)
    }

    /// Whether this tab stays — with the viewer's wish and the allow list.
    public func remains(_ tabs: String, deselected: Set<String> = []) -> Bool {
        TabScope.remains(
            tabs, isInChildMode: isInChildMode, deselected: deselected,
            channelApproval: rule.channelApproval)
    }

    /// Whether the schedule appears. **Never for a child**: it switches through the channels of
    /// an event, whatever group they are in, and there is no list for sports.
    public var showsSports: Bool { !isInChildMode }

    /// **The filter for channels — the same on every path** (AP52). Outside child mode the
    /// catalog is unchanged; the viewer's preferences remain the caller's business.
    public func channels(_ catalog: [Channel]) -> [Channel] {
        guard isInChildMode else { return catalog }
        return rule.channelApproval.isVisible(catalog)
    }

    /// Whether this channel may play — **scope, allow list and the switch for adult channels**,
    /// the same question as in the Live area (finding M4 of 25.09.).
    public func isPlaying(_ channel: Channel, isVisible: LivePreferences) -> Bool {
        guard deliversChannels else { return false }
        if isInChildMode, !rule.channelApproval.isAllowed(channel) { return false }
        return isVisible.allows(group: channel.group, isAdult: channel.isAdult)
    }

    /// What a press on a channel from outside plays — **the channel and its neighbours**,
    /// through the same filter, or `nil`.
    public func channelSelection(
        _ identifier: String, from catalog: [Channel], isVisible: LivePreferences
    ) -> (channel: Channel, nachbarn: [Channel])? {
        guard let channel = catalog.first(where: { $0.id == identifier }),
            isPlaying(channel, isVisible: isVisible)
        else { return nil }
        return (channel, isVisible.isVisible(channels(catalog)))
    }

    /// Whether this title may be **opened or played** — the filter of every path that bypasses
    /// the lists.
    ///
    /// **Three questions, and the title rule is the last** (finding B3 of 25.09.): first the
    /// origin, then the channel, then ``ProtectionRule/shows(_:)``. Portal, provider and
    /// channel titles carry no ratings, and "no rating" would let the title rule through.
    ///
    /// - Parameter herkunft: The name of the origin, computed from the **ID** and not from the
    ///   source the caller happens to hold; `nil` for the media server.
    public func opens(_ title: MediaItem, origin: String?) -> Bool {
        if let origin, !delivers(origin) { return false }
        if title.kind == .channel, !deliversChannels { return false }
        return rule.shows(title)
    }

    /// Whether the picture-in-picture window may go **back to full screen** (finding 2 of
    /// 25.09.).
    ///
    /// A channel must be in the catalog and be allowed to play; if it is not in it, only outside
    /// child mode. A title goes through ``opens(_:origin:)``; if it could not be looked up,
    /// the same applies as for the channel.
    public func returnTarget(
        _ target: PlaybackTarget, title: MediaItem?, origin: String?, channels: [Channel],
        isVisible: LivePreferences
    ) -> Bool {
        if target.kind == .live {
            guard let channel = channels.first(where: { $0.plays(target.url) }) else {
                // **`deliversChannels` is always true here when `!isInChildMode`** (finding 2026-09-27, e1,
                // small stuff): outside child mode
                // ``TabScope/deliversChannels(isInChildMode:channelApproval:)`` always returns `true` â
                // the second condition was dead weight.
                return !isInChildMode
            }
            return isPlaying(channel, isVisible: isVisible)
        }
        guard let title else { return !isInChildMode }
        return opens(title, origin: origin)
    }

    /// Whether this target is reachable — **also for paths that do not go via bar or tab** (a
    /// "To settings" button, a jump from outside).
    ///
    /// **An adult reaches every target**; what the device lock takes away from them is taken
    /// away by bar and tabs via ``remains(_:deselected:)`` and ``delivers(_:)``. **A child**
    /// reaches ``ChildTarget/forChildren`` and Live if its allow list permits something.
    /// Everything else is, for a child, not locked but **not there** — a dimmed entry would be
    /// an invitation.
    public func isAllowed(_ target: ChildTarget) -> Bool {
        guard withoutManagement else { return true }
        if ChildTarget.forChildren.contains(target) { return true }
        return target == .live && deliversChannels
    }
}

extension ProtectionRule {

    /// The scope of this rule — **the one question about child mode.**
    public var scope: ChildScope { ChildScope(self) }
}
