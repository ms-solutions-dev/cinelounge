import Foundation

/// What is set up on this TV: a media server, a channel list, both — or nothing yet.
///
/// **Two independent flags, explicitly not an enumerated type.** The obvious form would be
/// `enum { nurJellyfin, listOnly, beides }`. It is the wrong one: Both must remain
/// retrofittable in **both** directions, and with an enumeration every place that adds or
/// removes something would have to know the transition from every case to every other.
/// Whoever starts with a channel list and adds Jellyfin later must not have to start over —
/// with two flags, adding is an assignment, with an enumeration a conversion at every use
/// site.
///
/// The derived questions therefore live here and not in the views: Otherwise one view asks
/// `hasJellyfin`, the next `!hasPlaylist`, and when retrofitting, one of the two is no
/// longer right.
/// **Since AP41 (2026-09-21) a wrapper and not a source.** What is set up lives in the
/// ``ProfileKit/ProfileBook`` — there it belongs to the **person** and not to the device. This
/// type stays because a dozen views speak it and ``Area`` decides which area is the
/// starting point; rewriting it and the views in one day would mean checking two
/// restructurings in one step, and if something is missing afterwards, nobody knows which
/// one it was.
///
/// **``load(from:)`` still has exactly one caller**, and that is deliberate: `ProfileStartup`
/// uses it to read the old device state in order to build profiles from it on first launch.
/// It goes away on the day when no device comes from a version before AP41. **``save(to:)``
/// has none anymore** — the intermediate copy in the Keychain was dropped because
/// credentials now arise where they are set up: at sign-in, when accepting a channel list,
/// when switching on the portals. A copy that someone has to keep updating is a second truth
/// with a delay.
public struct AccountState: Sendable, Equatable {

    /// Whether a credential for a media server is stored.
    public var hasJellyfin: Bool

    /// Whether at least one channel list is stored.
    ///
    /// **Stored, not switched on.** A switched-off list counts too, although nothing can be seen
    /// from it. The reason is the consequence of the other way: Whoever temporarily switches off
    /// their only list would otherwise be offered setup again — as if the typed-in credential
    /// were lost. On tvOS typing is the most expensive operation; this scare must not arise.
    public var hasPlaylist: Bool

    /// Whether the portals are switched on.
    ///
    /// **The third way, and it is not a stopgap** (G2, 2026-09-07). Until then this state knew only
    /// "has Jellyfin" and "has a list"; whoever wants to use only the portals fell between the
    /// two and was not let through by the setup — although the area has been built since E42.
    ///
    /// **A wish and not a credential.** The other two flags stand for something stored: an
    /// access token, a list. Here there is nothing to store — what a portal is, the bridge
    /// knows, and where the bridge stands is a setting and not a sign-in. What the user decides
    /// is **whether they want it**.
    public var hasPortals: Bool

    public init(
        hasJellyfin: Bool = false, hasPlaylist: Bool = false, hasPortals: Bool = false
    ) {
        self.hasJellyfin = hasJellyfin
        self.hasPlaylist = hasPlaylist
        self.hasPortals = hasPortals
    }

    // MARK: - Fragen der Oberfläche

    /// Whether anything is set up at all yet.
    ///
    /// If not, the start belongs to the choice between the two ways — and not to the sign-in at
    /// a media server. A user with a purchased channel list has no business here otherwise and
    /// takes the app for the wrong program.
    public var isConfigured: Bool { hasJellyfin || hasPlaylist || hasPortals }

    /// Whether the media library pill appears — Home, series, movies, home.
    ///
    /// All four areas come from the media server. Without it, a pill with four empty pages would
    /// stand there, and that looks like a bug, not like a missing setup.
    public var showsMediaBar: Bool { hasJellyfin }

    /// Whether the Live area appears.
    public var showsLiveArea: Bool { hasPlaylist }

    /// Whether the interface should offer retrofitting a media server.
    ///
    /// As a question of its own and not as `!hasJellyfin` at the use site: An area that is simply
    /// omitted looks broken. Where something is missing, the way to it must be shown — and that
    /// is the same condition, only with the opposite intent.
    public var offersJellyfinSetup: Bool { !hasJellyfin }

    /// Whether the interface should offer retrofitting a channel list.
    public var offersPlaylistSetup: Bool { !hasPlaylist }

    /// Whether the portals area appears.
    public var showsPortalArea: Bool { hasPortals }

    /// Whether the interface should offer retrofitting the portals.
    public var offersPortalSetup: Bool { !hasPortals }

    // MARK: - Wohin die Oberfläche zeigt

    /// The three places to be, between which this state decides.
    ///
    /// Deliberately coarse: Within the media library there are further areas, but none of them
    /// depends on this state. Subdivided more finely, this enumeration would have to grow with
    /// every new view.
    public enum Area: Sendable, Equatable, CaseIterable {
        /// The choice between the two ways.
        case setup
        /// The media library of the media server.
        case media
        /// The Live area made of the channel lists.
        case live
        /// Third-party sources via the bridge — the way without a server of one's own.
        case portals
    }

    /// Whether this place has anything to show in the current state.
    public func allows(_ area: Area) -> Bool {
        switch area {
        case .setup: !isConfigured
        case .media: hasJellyfin
        case .live: hasPlaylist
        case .portals: hasPortals
        }
    }

    /// Where the app lands at launch.
    ///
    /// The media library takes precedence over the Live area when both are set up — not because
    /// it would be more important, but because an order is needed and this is the only one that
    /// does not change when a channel list is added. Whoever wants the Live area as the start
    /// stays there via ``landing(from:)``.
    public var landing: Area {
        if hasJellyfin { return .media }
        if hasPlaylist { return .live }
        // **Last and not first.** The same reasoning as between media library and Live: An order is
        // needed, and this is the only one that does not change when a way is added. Whoever wants
        // the portals as the start stays there via ``landing(from:)``.
        if hasPortals { return .portals }
        // **Whoever removes everything lands in the way choice again — decided on 2026-09-11
        // (AP24), against the phone's answer.**
        //
        // **Addendum of the same day (AP29):** The second way to the settings that the phone
        // answer presupposes now exists — ``MainView`` works without a media server, and with it
        // the sidebar. **For this case that still changes nothing:** Whoever has set up *nothing at
        // all* also has no area in which the sidebar would stand. `.setup` remains the fallback
        // door — only it is now the door for "nothing there" and no longer the one for "no media
        // server".
        //
        // The phone project separated `setup.done` from "something is there" on 2026-09-06, with the
        // reasoning: *"Whoever removes everything has seen the setup anyway."* On the phone that is
        // right. **Here it cannot be adopted**, and the reason is in the source next to it: The
        // settings are reachable only via the media library. Whoever has nothing left and is not
        // sent to the setup would have **no way to anything anymore** — on tvOS a screen that the
        // remote cannot lead out of.
        //
        return .setup
    }

    /// Where to go from a place once that place has nothing left to show.
    ///
    /// **This is the way out**, and it is the reason this computation is not in a view: Whoever
    /// has set up both, stands in the media library and removes their media server there must
    /// land in the Live area. Without this redirect they would stay on a page whose content no
    /// longer exists — on tvOS a black screen without explanation that the remote cannot lead
    /// out of.
    ///
    /// As long as the place still holds, it is left untouched. Otherwise the app would jump out
    /// of the area the user was in when a channel list was entered.
    public func landing(from current: Area) -> Area {
        allows(current) ? current : landing
    }

    // MARK: - Ablage

    static let jellyfinKey = "account.hasJellyfin"
    static let playlistKey = "account.hasPlaylist"
    static let portalsKey = "account.hasPortals"

    /// Reads the flags.
    ///
    /// **It is an intermediate copy, and that is deliberate.** The truth is elsewhere: the
    /// server credential in the Keychain, the channel lists in their own store. Whoever only
    /// wants to know which of the two ways the user took would otherwise have to open both and
    /// evaluate both — two foreign building blocks for a question with two yes-or-no answers.
    ///
    /// An intermediate copy can go stale, and that is the trap: Whoever takes the flags for the
    /// truth shows a media library for a credential that no longer exists. That is why the
    /// derived statement applies as soon as it is available and is written back with
    /// ``save(to:)``.
    public static func load(from store: any KeyValueStore) -> AccountState {
        AccountState(
            hasJellyfin: (try? store.value(for: jellyfinKey)) == "1",
            hasPlaylist: (try? store.value(for: playlistKey)) == "1",
            hasPortals: (try? store.value(for: portalsKey)) == "1"
        )
    }

    public func save(to store: any KeyValueStore) {
        // `set("0", ...)` would be wrong: The store would then distinguish "never set up" from
        // "removed" without anyone reading that difference — and a remnant would stay forever.
        write(hasJellyfin, for: Self.jellyfinKey, to: store)
        write(hasPlaylist, for: Self.playlistKey, to: store)
        write(hasPortals, for: Self.portalsKey, to: store)
    }

    private func write(_ flag: Bool, for key: String, to store: any KeyValueStore) {
        if flag {
            try? store.set("1", for: key)
        } else {
            try? store.remove(key)
        }
    }
}
