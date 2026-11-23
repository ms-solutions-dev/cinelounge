import Foundation
import Testing

@testable import Core

/// The shelf also shows IPTV VOD and CL-Server, as with the big streaming apps (product decision, 2026-09-28).
@Suite("Top Shelf: contributions from the profile state")
struct TopShelfExtraTests {

    private func location(
        _ title: String, location: TimeInterval?, watched: Bool = false, favorite: Bool = false,
        forward seconds: TimeInterval
    ) -> StateRecording.TitlePosition {
        var s = StateRecording.TitlePosition(
            location: location, duration: 3600, seen: watched, favorite: favorite)
        s.title = title
        s.image = "https://image.example/\(title).jpg"
        s.recent = Date(timeIntervalSinceNow: -seconds)
        return s
    }

    @Test("Continue Watching: started, not watched, newest first")
    func continueWatching() {
        let state = StateRecording(titlePositions: [
            "iptv#film#1": location("Old", location: 600, forward: 7200),
            "serieshub|x": location("New", location: 60, forward: 60),
            "iptv#film#2": location("Done", location: 3500, watched: true, forward: 10),
            "iptv#film#3": location("Never", location: nil, forward: 5),
        ])
        #expect(TopShelfEntry.from(state, mode: .resume).map(\.title) == ["New", "Old"])
    }

    @Test("Favorites takes the favorites, Latest takes nothing")
    func favorites() {
        let state = StateRecording(titlePositions: [
            "a": location("Darling", location: nil, favorite: true, forward: 1),
            "b": location("Whatever", location: 10, forward: 1),
        ])
        #expect(TopShelfEntry.from(state, mode: .favorites).map(\.title) == ["Darling"])
        #expect(TopShelfEntry.from(state, mode: .latest).isEmpty)
    }

    @Test("Without Jellyfin there is a shelf if the app contributes something")
    func withoutJellyfin() {
        let filter = ShelfFilter(
            childMode: false, applies: false, limit: nil, blocksUnrecognized: false, assignments: [:])
        let entry = TopShelfEntry(id: "a", title: "A", image: nil, recent: nil)
        #expect(TopShelfBridge.context(credentials: nil, profile: "p", filter: filter, mode: .resume) == nil)
        let context = TopShelfBridge.context(
            credentials: nil, profile: "p", filter: filter, mode: .resume, extras: [entry])
        #expect(context?.extras == [entry])
        #expect(context?.jellyfin == nil)
    }
}
