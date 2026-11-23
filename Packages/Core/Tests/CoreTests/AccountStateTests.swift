import Foundation
import Testing

@testable import Core

/// Two flags instead of one enumerated state — the whole retrofittability of the app
/// depends on it. That is why not only each of the four states is checked, but every
/// transition between them in both directions.
@Suite("What is set up")
struct AccountStateTests {

    // MARK: - The four states

    /// A state pair together with the answers it has to give.
    ///
    /// As a table and not as four individual checks: Only that way is it noticed when a
    /// derived question deviates in **one** of the four cases.
    struct Expectation: Sendable {
        let jellyfin: Bool
        let playlist: Bool
        let mediaBar: Bool
        let liveArea: Bool
        let landing: AccountState.Area
    }

    @Test(
        "Each of the four states answers the UI's questions unambiguously",
        arguments: [
            Expectation(
                jellyfin: false, playlist: false, mediaBar: false, liveArea: false, landing: .setup),
            Expectation(
                jellyfin: true, playlist: false, mediaBar: true, liveArea: false, landing: .media),
            Expectation(
                jellyfin: false, playlist: true, mediaBar: false, liveArea: true, landing: .live),
            Expectation(
                jellyfin: true, playlist: true, mediaBar: true, liveArea: true, landing: .media),
        ]
    )
    func allFourStates(expected: Expectation) {
        // If one of the derived questions slips — say because someone attaches the library
        // pill to `isConfigured` instead of to Jellyfin —, the app shows a user with a pure
        // channel list four empty pages, and that looks like an error instead of a missing
        // setup.
        let state = AccountState(hasJellyfin: expected.jellyfin, hasPlaylist: expected.playlist)

        #expect(state.isConfigured == (expected.jellyfin || expected.playlist))
        #expect(state.showsMediaBar == expected.mediaBar)
        #expect(state.showsLiveArea == expected.liveArea)
        #expect(state.landing == expected.landing)
        #expect(state.offersJellyfinSetup == !expected.jellyfin)
        #expect(state.offersPlaylistSetup == !expected.playlist)
    }

    @Test("Without anything the start leads to the selection and to no area")
    func nothingConfigured() {
        // The only state in which the choice between the two paths may appear. If `.setup`
        // were allowed later too, the setup would come back at every start — and the user
        // would take their access for lost.
        let state = AccountState()

        #expect(state.allows(.setup))
        #expect(!state.allows(.media))
        #expect(!state.allows(.live))
    }

    // MARK: - Adding later in both directions

    @Test("Anyone who starts with a channel list keeps it when adding Jellyfin")
    func retrofitJellyfinKeepsPlaylist() {
        // The actual requirement. With an enumerated state this step would be a transition
        // from "list only" to "both" that every place would have to know; here it is an
        // assignment. If the test failed, adding the server would have switched off the
        // channel list — the Live area would have disappeared after signing in.
        var state = AccountState(hasPlaylist: true)
        #expect(state.landing == .live)

        state.hasJellyfin = true

        #expect(state.hasPlaylist, "the list stays set up")
        #expect(state.showsLiveArea)
        #expect(state.showsMediaBar)
        #expect(!state.offersJellyfinSetup, "the way to add it later disappears")
    }

    @Test("Anyone who starts with Jellyfin keeps it when adding a channel list")
    func retrofitPlaylistKeepsJellyfin() {
        // The same check in the other direction, and it is not superfluous: The path via
        // the settings is a different one from the one via the setup, and only one of the
        // two would be right by accident with an enumeration.
        var state = AccountState(hasJellyfin: true)

        state.hasPlaylist = true

        #expect(state.hasJellyfin)
        #expect(state.showsMediaBar)
        #expect(state.showsLiveArea)
        #expect(!state.offersPlaylistSetup)
    }

    @Test("When adding, the user stays where they are")
    func retrofitDoesNotMoveTheUser() {
        // Without this condition the app jumps out of the area the user is currently in
        // when a channel list is entered. That looks like a crash although something was
        // only added.
        var onlyPlaylist = AccountState(hasPlaylist: true)
        onlyPlaylist.hasJellyfin = true
        #expect(onlyPlaylist.landing(from: .live) == .live)

        var onlyJellyfin = AccountState(hasJellyfin: true)
        onlyJellyfin.hasPlaylist = true
        #expect(onlyJellyfin.landing(from: .media) == .media)
    }

    // MARK: - Der Weg heraus

    @Test("Anyone who removes Jellyfin lands in the Live area")
    func removingJellyfinLandsInLive() {
        // The case ``AccountState/landing(from:)`` is about at all: Without the redirect
        // the library would remain as a location whose content no longer exists — on the TV
        // a black picture the remote does not lead out of.
        var state = AccountState(hasJellyfin: true, hasPlaylist: true)

        state.hasJellyfin = false

        #expect(state.landing(from: .media) == .live)
        #expect(state.isConfigured, "the channel list carries on")
        #expect(!state.allows(.setup), "no return to setup")
    }

    @Test("Anyone who removes the channel list lands in the library")
    func removingPlaylistLandsInMedia() {
        // The opposite direction. With an order that prefers Jellyfin it is easily right —
        // that is why it stands here next to the reverse case, which is not.
        var state = AccountState(hasJellyfin: true, hasPlaylist: true)

        state.hasPlaylist = false

        #expect(state.landing(from: .live) == .media)
        #expect(state.offersPlaylistSetup, "the way to add it later reappears")
    }

    @Test("Anyone who removes the last one lands in setup and not in the void")
    func removingEverythingLandsInSetup() {
        // Otherwise the app would stand on a place with no content and no way back.
        var state = AccountState(hasJellyfin: true)

        state.hasJellyfin = false

        #expect(state.landing(from: .media) == .setup)
        #expect(state.landing == .setup)
    }

    // MARK: - Ablage

    @Test(
        "Each of the four states survives saving and loading",
        arguments: [
            AccountState(),
            AccountState(hasJellyfin: true),
            AccountState(hasPlaylist: true),
            AccountState(hasJellyfin: true, hasPlaylist: true),
        ]
    )
    func survivesStorage(state: AccountState) {
        // If one of the flags is lost when storing, the app demands at the next start a
        // setup that was done long ago — and the user types in an access for the second
        // time.
        let store = InMemoryStore()

        state.save(to: store)

        #expect(AccountState.load(from: store) == state)
    }

    @Test("The two flags are stored separately and not swapped")
    func keysAreDistinct() {
        // A swapped key would not be noticed with "both set up" and would mislead exactly in
        // the case where only one is set up: After the restart the wrong area would appear.
        let store = InMemoryStore()

        AccountState(hasJellyfin: true).save(to: store)

        #expect((try? store.value(for: AccountState.jellyfinKey)) == "1")
        #expect((try? store.value(for: AccountState.playlistKey)) == nil)
        #expect(AccountState.load(from: store) == AccountState(hasJellyfin: true))
    }

    @Test("Removing clears the entry and leaves no remainder")
    func removalClearsStorage() {
        // If an entry with the value "0" stayed in place, the store would distinguish
        // between "never set up" and "removed" without anyone reading that distinction —
        // and a later check for the presence of the key would be wrong.
        let store = InMemoryStore()

        AccountState(hasJellyfin: true, hasPlaylist: true).save(to: store)
        AccountState().save(to: store)

        #expect((try? store.value(for: AccountState.jellyfinKey)) == nil)
        #expect((try? store.value(for: AccountState.playlistKey)) == nil)
        #expect(AccountState.load(from: store) == AccountState())
    }

    @Test("An empty store means nothing is set up")
    func emptyStoreMeansNothing() {
        // The state at first start. If it accidentally yielded a set-up access, the user
        // would see an empty library instead of the choice between the two paths.
        #expect(AccountState.load(from: InMemoryStore()) == AccountState())
    }

    @Test("A foreign value in the store does not count as set up")
    func foreignValueIsNotConfigured() {
        // The store is the Keychain, which other versions of the app have also written to.
        // A "0" or "false" from there must not be read as "yes" — otherwise the app leads
        // into an area without content.
        let store = InMemoryStore()
        try? store.set("0", for: AccountState.jellyfinKey)
        try? store.set("false", for: AccountState.playlistKey)

        #expect(AccountState.load(from: store) == AccountState())
    }
}

// MARK: - Der dritte Weg (G2)

/// **Portals alone are a setup.**
///
/// Until 2026-09-07 this state knew only "has Jellyfin" and "has a list"; anyone who
/// wanted the portals alone counted as not set up and was sent back to the path
/// selection — although the area has been built since E42.
@Test func portalsAloneAreConfigured() {
    let state = AccountState(hasPortals: true)
    #expect(state.isConfigured)
    #expect(state.landing == .portals)
    #expect(state.allows(.portals))
    #expect(state.allows(.media) == false)
}

/// **The order stays: library, Live, portals.**
///
/// Not by rank, but because an order is needed and this is the only one that does not
/// change when a path is added.
@Test func portalsRankLastInOrder() {
    #expect(AccountState(hasJellyfin: true, hasPortals: true).landing == .media)
    #expect(AccountState(hasPlaylist: true, hasPortals: true).landing == .live)
    #expect(AccountState(hasPortals: true).landing == .portals)
}

/// **Whoever switches the portals on stays where they are.**
///
/// As long as the location still holds, it stays untouched — otherwise the app would
/// jump out of the area the user is currently in when switching on.
@Test func enablingDoesNotPullAnyoneOutOfTheirArea() {
    let state = AccountState(hasJellyfin: true, hasPortals: true)
    #expect(state.landing(from: .media) == .media)
}

/// **If the last other path drops out, the way leads to the portals and not into the
/// void.**
@Test func withoutServerTheWayLeadsToPortals() {
    let state = AccountState(hasPortals: true)
    #expect(state.landing(from: .media) == .portals)
}

/// The third flag survives the store — and a `false` leaves no remainder.
@Test func portalMarkerSurvivesTheStore() {
    let store = InMemoryStore()
    AccountState(hasPortals: true).save(to: store)
    #expect(AccountState.load(from: store).hasPortals)

    AccountState(hasPortals: false).save(to: store)
    #expect(AccountState.load(from: store).hasPortals == false)
    #expect((try? store.value(for: AccountState.portalsKey)) == nil)
}

/// **Whoever removes everything again lands in the path selection** — the decision of
/// 2026-09-11 (AP24), recorded as a check.
///
/// **It stands here because it falls against the answer of the sister project.** On
/// the phone, since 2026-09-06: `setup.done` is separate from "there is something", because
/// *"Anyone who removes everything again has seen the setup anyway."* Anyone who wants
/// to align this here one day — and the wish is understandable — has to build a second
/// way to the settings **beforehand**: Today it leads exclusively through the library.
/// Without it `.media` or `.live` without an access would be a screen without content
/// and without an exit.
///
/// A silent alignment therefore breaks at this line.
@Test("Without any access, setup is the fallback door")
func withoutAccessItGoesToSetup() {
    let empty = AccountState(hasJellyfin: false, hasPlaylist: false, hasPortals: false)

    #expect(empty.landing == .setup)
    // **Also from on the road.** Anyone who stood in the library and removes their last
    // access there must not stay there — that is the way out that `landing(from:)`
    // builds, and without an access it ends at the same place.
    for place in [AccountState.Area.media, .live, .portals] {
        #expect(empty.landing(from: place) == .setup, "\(place) without access is a dead end")
    }
}
