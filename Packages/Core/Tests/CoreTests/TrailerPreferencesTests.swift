import Foundation
import Testing

@testable import Core

/// The setting decides whether sound and picture start by themselves while
/// browsing a library. A bug here is not cosmetic: over the tunnel
/// a measured 0.3 Mbit/s is available, and a trailer that loads there without
/// being asked makes the whole view unusable.
@Suite("Trailer setting")
struct TrailerPreferencesTests {

    @Test("Without an entry the trailer starts by itself")
    func defaultIsOn() {
        // The default must be the nice one: the app is used predominantly on the
        // home network, and there the autostart is the reason why the
        // information column is more than a wall of text.
        let preferences = TrailerPreferences.load(from: InMemoryStore())

        #expect(preferences.autostarts)
        #expect(preferences.dwell == TrailerPreferences.defaultDwell)
    }

    @Test("Switching off and on again survives saving")
    func survivesStorage() {
        // The switch is the only handle on the go. If it came back to "on" after the
        // app restarted, it would be worthless — one would have to flip it at
        // every launch again.
        let store = InMemoryStore()

        var preferences = TrailerPreferences()
        preferences.autostarts = false
        preferences.save(to: store)

        #expect(!TrailerPreferences.load(from: store).autostarts)

        preferences.autostarts = true
        preferences.save(to: store)

        #expect(TrailerPreferences.load(from: store).autostarts)
        #expect(
            (try? store.value(for: TrailerPreferences.autostartKey)) == nil,
            "the default is removed instead of written"
        )
    }

    @Test("The dwell time survives saving and loading unchanged")
    func dwellRoundTrip() {
        // It is stored as a value so that it can be changed. If it got lost
        // on saving, the code would contain a setting that does nothing —
        // and the next change to it would be ineffective, without anything missing.
        let store = InMemoryStore()

        TrailerPreferences(autostarts: false, dwell: 5).save(to: store)
        let loaded = TrailerPreferences.load(from: store)

        #expect(loaded.dwell == 5)
        #expect(!loaded.autostarts, "both values must come through together")
    }

    @Test("A dwell time of zero is not accepted")
    func zeroDwellIsClamped() {
        // At zero the trailer starts at the moment the focus changes. When
        // browsing a library of three hundred titles that would be
        // three hundred requests and three hundred aborted playbacks — exactly the
        // case the dwell time exists for.
        let store = InMemoryStore()
        try? store.set("0", for: TrailerPreferences.dwellKey)

        #expect(TrailerPreferences.load(from: store).dwell >= TrailerPreferences.minimumDwell)
        #expect(TrailerPreferences(dwell: -5).dwell >= TrailerPreferences.minimumDwell)
    }

    @Test("An absurdly long dwell time is capped")
    func hugeDwellIsClamped() {
        // A duration of an hour cannot be told apart from "off".
        // Whoever does not want the autostart should turn it off and not push a number
        // so high that nobody can tell whether the view is broken.
        #expect(TrailerPreferences(dwell: 3600).dwell == TrailerPreferences.maximumDwell)
    }

    @Test("An unreadable entry does not switch off autostart")
    func garbageStaysOn() {
        // A damaged entry must not feign a setting that nobody
        // made. Otherwise one looks for the cause in the app while it sits in the
        // store — and the switch shows "on" meanwhile.
        let store = InMemoryStore()
        try? store.set("vielleicht", for: TrailerPreferences.autostartKey)
        try? store.set("bald", for: TrailerPreferences.dwellKey)

        let loaded = TrailerPreferences.load(from: store)

        #expect(loaded.autostarts)
        #expect(loaded.dwell == TrailerPreferences.defaultDwell)
    }
}
