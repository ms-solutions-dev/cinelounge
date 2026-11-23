import Foundation
import Testing

@testable import Core

/// What is hidden stays hidden everywhere.
///
/// **The finding of 2026-08-29:** Groups can be hidden in channel lists, and
/// that also works in the live preview — but when a channel is already
/// open and the user navigates into the group, all groups still
/// show up there. The cause was not a forgotten condition but a second
/// source: The player's overlay fetches the full catalog itself
/// when the one passed in is empty — and "full" meant unfiltered.
///
/// What is tested is therefore the **rule**, not the view: Whoever filters the channels
/// filters the groups as well, because the group list is derived from the channels.
@Suite("Hidden groups, everywhere")
struct LiveVisibilityTests {

    private func makeChannel(_ name: String, group: String?, adult: Bool = false) -> Channel {
        Channel(
            id: name,
            name: name,
            streamURL: URL(string: "http://host/live/u/p/\(name).m3u8")!,
            playlistID: "p1",
            group: group,
            isAdult: adult
        )
    }

    private var catalog: [Channel] {
        [
            makeChannel("TELVE 1", group: "Türkei"),
            makeChannel("Lodos TV", group: "Türkei"),
            makeChannel("Das Nordlicht", group: "Deutschland"),
            makeChannel("Sola Sport", group: "Sport"),
            makeChannel("Ungrouped", group: nil),
        ]
    }

    @Test("Without hiding, everything stays")
    func nothingHidden() {
        let preferences = LivePreferences()

        #expect(preferences.isVisible(catalog).count == 5)
    }

    @Test("A hidden group takes its channels with it")
    func groupHidden() {
        let preferences = LivePreferences(hiddenGroups: ["Türkei"])

        let remaining = preferences.isVisible(catalog)

        #expect(remaining.count == 3)
        #expect(!remaining.contains { $0.group == "Türkei" })
    }

    /// **And with that the group list too.** It is derived from the channels;
    /// that is exactly the reason why there is no separate
    /// group filter here.
    @Test("The groups of the remaining channels no longer list the hidden one")
    func groupListFollows() {
        let preferences = LivePreferences(hiddenGroups: ["Türkei", "Sport"])

        let groups = Set(preferences.isVisible(catalog).compactMap(\.group))

        #expect(groups == ["Deutschland"])
    }

    /// A channel without a group must not disappear with them — it belongs to none
    /// that anybody could have hidden.
    @Test("A channel without a group stays")
    func withoutGroup() {
        let preferences = LivePreferences(hiddenGroups: ["Türkei", "Deutschland", "Sport"])

        #expect(preferences.isVisible(catalog).map(\.name) == ["Ungrouped"])
    }

    /// The second condition applies here too, otherwise it would be a third place where
    /// it can be forgotten.
    @Test("Adult content follows its own setting")
    func adult() {
        let catalog = catalog + [makeChannel("XX", group: "Sport", adult: true)]

        #expect(!LivePreferences().isVisible(catalog).contains { $0.isAdult })
        #expect(
            LivePreferences(showsAdultChannels: true).isVisible(catalog).contains { $0.isAdult })
    }
}

/// The overview area as a switch.
///
/// **The product requirement of 2026-08-29:** The preview area is only needed for
/// channel search etc. … not everybody needs it, and if someone does, they can
/// switch it on in Settings.
///
/// What is tested is the store, because that is exactly where it went wrong twice: A
/// switch that does not survive a restart looks like one that does
/// nothing.
@Suite("The overview area can be switched off")
struct LiveOverviewTests {

    @Test("Out of the box no area precedes playback")
    func preset() {
        #expect(!LivePreferences().showsBrowseArea)
        #expect(!LivePreferences.load(from: InMemoryStore()).showsBrowseArea)
    }

    @Test("Switched on, it survives a restart")
    func remains() {
        let bucket = InMemoryStore()
        var preferences = LivePreferences()
        preferences.setShowsBrowseArea(true)
        preferences.save(to: bucket)

        #expect(LivePreferences.load(from: bucket).showsBrowseArea)
    }

    /// And off means off again — a switch that only works in one direction
    /// is worse than none.
    @Test("Switched off again, it stays off")
    func back() {
        let bucket = InMemoryStore()
        var preferences = LivePreferences()
        preferences.setShowsBrowseArea(true)
        preferences.save(to: bucket)

        preferences.setShowsBrowseArea(false)
        preferences.save(to: bucket)

        #expect(!LivePreferences.load(from: bucket).showsBrowseArea)
    }

    /// It must not touch the other settings — they live in
    /// the same store.
    @Test("It leaves the other settings alone")
    func untouched() {
        let bucket = InMemoryStore()
        var preferences = LivePreferences(hiddenGroups: ["Sport"], previewsChannels: true)
        preferences.setShowsBrowseArea(true)
        preferences.save(to: bucket)

        let loaded = LivePreferences.load(from: bucket)

        #expect(loaded.showsBrowseArea)
        #expect(loaded.previewsChannels)
        #expect(loaded.hiddenGroups == ["Sport"])
    }
}
