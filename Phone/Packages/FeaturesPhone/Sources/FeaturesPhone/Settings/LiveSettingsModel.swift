import Core
import Foundation
import Observation
import ParentalControls
import PlaylistKit

/// What the Live area sets — **and where it is written.**
///
/// **Until 2026-09-06. `LivePreferences` was read and written in three places, but never where
/// one sets it.** The screen for it was missing entirely; groups could only be hidden via
/// Home, and the sports filters did not even exist as a field. A chip field that stores
/// nothing is a screen that forgets on leaving — and that is only noticed when one comes
/// back.
///
/// **What this model does NOT touch, although `LivePreferences` holds it:**
/// `previewsChannels` — there is no channel preview on the phone. **An entry from here
/// would be an entry to nothing.** `showsBrowseArea` ("Overview before playback") is back
/// since 2026-09-26 (decision 27, C14): the Live tab now jumps like the TV into the last
/// watched channel, and the switch thereby has an effect.
///
/// **Saved on toggle and not on "Done".** Every other setting in this app takes effect
/// immediately; a screen with a save button would be the only one, and whoever overlooks it
/// loses their work.
///
/// **Read fresh, change, write back — on every single action.** `LivePreferences` stores
/// all its fields in one go. A copy held here would write the hidden groups back as they
/// looked when the screen opened; whoever flips the adult switch in parental controls in the
/// meantime would lose it on the next chip tap. The same rule as in
/// ``ParentalControlsState``.
@MainActor
@Observable
public final class LiveSettingsModel {

    public private(set) var preferences: LivePreferences

    /// Which sports the schedule shows — **the same key as on the TV**
    /// (``Core/SportFilterSettings``, AP58 R5, finding L4). Until 2026-09-26 the choice lay
    /// here as a field in ``Core/LivePreferences`` under a key of its own.
    public private(set) var sportSelection: SportFilterSettings
    /// The online sync of kickoff times — **the same key as on the TV**
    /// (``Core/SportSyncSettings``, B6). It supplies the "confirmed" seal and the "Covered"
    /// filter; it can be switched off for everyone who does not want requests to a third-party
    /// source.
    public private(set) var sync: SportSyncSettings
    public private(set) var groupsRead = 0
    public private(set) var groupsVisible = 0

    /// Which tabs the viewer has deselected.
    public private(set) var deselected: TabSelection

    private let source: (any ChannelListingSource)?
    private let keychain: any KeyValueStore
    private let state: ParentalControlsState?

    public init(
        source: (any ChannelListingSource)? = nil,
        state: ParentalControlsState? = nil,
        keychain: (any KeyValueStore)? = nil,
        tabStore: (any KeyValueStore)? = nil
    ) {
        let bucket = keychain ?? SecureStore()
        self.source = source
        self.state = state
        self.keychain = bucket
        self.preferences = LivePreferences.load(from: bucket)
        self.sportSelection = SportFilterSettings.load(from: bucket)
        self.sync = SportSyncSettings.load(from: bucket)
        self.deselected = TabSelection(store: tabStore)
    }

    // MARK: - What is shown

    public var showsLive: Bool { deselected.shows(Tab.live.rawValue) }

    public func showsSports(_ kind: SportKind) -> Bool { sportSelection.isEnabled(kind) }

    public var visibleSports: Int {
        SportKind.allCases.count { sportSelection.isEnabled($0) }
    }

    /// The state of parental controls as a value column — "on" or "off".
    ///
    /// **The same information as in the settings root, from the same source.** Two places that
    /// compute the same state differently are two opportunities to answer it differently.
    public var backupValue: String {
        SettingsModel.text(
            (state?.rule.applies ?? false) ? "common.on" : "common.off")
    }

    // MARK: - What is changed

    public func set(showsLive on: Bool) {
        deselected.set(Tab.live.rawValue, isVisible: on)
    }

    /// Whether "Live" first shows the overview or goes straight to the last watched channel
    /// (C14).
    public var showsOverview: Bool { preferences.showsBrowseArea }

    public func set(overview on: Bool) {
        update { $0.setShowsBrowseArea(on) }
    }

    public func set(sync on: Bool) {
        var fresh = SportSyncSettings.load(from: keychain)
        fresh.isEnabled = on
        fresh.save(to: keychain)
        sync = fresh
    }

    /// **Read fresh, change, write back** — the same rule as for ``update(_:)``.
    public func setEnabled(sport kind: SportKind) {
        changeSport { $0.toggle(kind) }
    }

    public func setAllSports(_ isVisible: Bool) {
        changeSport { $0.setAll(enabled: isVisible) }
    }

    private func changeSport(_ mutate: (inout SportFilterSettings) -> Void) {
        var fresh = SportFilterSettings.load(from: keychain)
        mutate(&fresh)
        fresh.save(to: keychain)
        sportSelection = fresh
    }

    private func update(_ mutate: (inout LivePreferences) -> Void) {
        var fresh = LivePreferences.load(from: keychain)
        mutate(&fresh)
        fresh.save(to: keychain)
        preferences = fresh
    }

    // MARK: - The group counts

    /// Counts what the provider carries and how much of it is visible.
    ///
    /// **Without a fetch there is no number, and then a sentence stands instead of a row.**
    /// Before the first visit to the Live area no groups have been read; "0 of 0" would be a
    /// number that looks like an error.
    public func load() async {
        guard let source else { return }
        let catalog = await source.channels()
        let all = Set(catalog.channels.map { $0.group ?? ChannelGroup.unnamed })
        groupsRead = all.count
        groupsVisible = all.count { preferences.allows(group: $0) }
    }
}
