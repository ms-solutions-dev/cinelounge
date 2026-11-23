import CloudSync
import Core
import Foundation
import Testing

@testable import ProfileKit

/// The state as records and back — without zone, without account, without network.
@Suite("The state as records")
struct StillMappingTests {

    let yesterday = Date(timeIntervalSince1970: 1_758_400_000)

    func sample() -> StateRecording {
        StateRecording(
            lastChannel: ["": "ahorn-hd", "xtream|panel.example|max": "telve1-hd"],
            titlePositions: [
                "xtream|panel.example|max#4711": .init(
                    location: 4350, duration: 7200, seen: false, favorite: true,
                    title: "Der Pakuro", kind: .movie, image: "plakat/4711", recent: yesterday),
                "jellyfin#abc": .init(location: nil, duration: nil, seen: true, favorite: false),
            ],
            channelFavorites: ["das erste hd", "telve 1 hd"],
            groupOrder: ["Sport", "Nachrichten"],
            hiddenGroups: ["Erwachsene"])
    }

    @Test("Round trip loses nothing")
    func roundTrip() {
        let state = sample()
        #expect(StillMapping.state(from: StillMapping.wordings(forItem: state)) == state)
    }

    @Test("The order of the records does not matter")
    func jumbled() {
        let state = sample()
        let mixed = StillMapping.wordings(forItem: state).shuffled()
        #expect(StillMapping.state(from: mixed) == state)
    }

    /// **One record per title, not one for everything.** Otherwise two devices would fight over
    /// the same row with every film — living room watches a film, bedroom a
    /// series, and one of the two loses.
    @Test("Every title gets its own record")
    func onePerTitle() {
        let wordings = StillMapping.wordings(forItem: sample())
            .filter { $0.contentType == StillMapping.stillType }
        #expect(wordings.count == 2)
        #expect(Set(wordings.map(\.name)) == ["xtream|panel.example|max#4711", "jellyfin#abc"])
    }

    /// **Deselecting must be a deletion.** As a list in one field, a
    /// conflict could be merged by union — but a union does not distinguish removed from
    /// not-yet-added, and the deselected channel would come back.
    @Test("Every channel favorite gets its own record")
    func onePerFavorite() {
        let wordings = StillMapping.wordings(forItem: sample())
            .filter { $0.contentType == StillMapping.channelFavoriteType }
        #expect(wordings.map(\.name) == ["das erste hd", "telve 1 hd"])

        // Taking one away means: one fewer — and not "it stays in the list".
        let without = wordings.filter { $0.name != "telve 1 hd" }
        #expect(StillMapping.state(from: without).channelFavorites == ["das erste hd"])
    }

    /// The empty list key means "last overall" (``Core/StateRecording``) and
    /// therefore gets a name **without** a dot — `lastChannel.` would be a key
    /// with an invisible end.
    @Test("Last overall and last per list are two rows")
    func lastChannel() {
        let wordings = StillMapping.settings(forItem: sample())
        #expect(wordings.contains { $0.name == "letzterSender" })
        #expect(wordings.contains { $0.name == "letzterSender.xtream|panel.example|max" })
        #expect(!wordings.contains { $0.name == "letzterSender." })
    }

    /// **A group name may carry any printable character** — comma and semicolon
    /// included. A separator that can occur in the value eventually splits wrongly,
    /// and silently: One group becomes two, and both look plausible.
    @Test("Group names with commas and semicolons survive")
    func separator() {
        let state = StateRecording(
            groupOrder: ["Sport; Fußball", "Nachrichten, national", "A|B"])
        let back = StillMapping.state(from: StillMapping.wordings(forItem: state))
        #expect(back.groupOrder == state.groupOrder)
    }

    /// Empty fields are left out instead of standing there empty. On reading this is the same
    /// case — when searching in the dashboard it is not.
    @Test("A title without a profile sheet carries no empty fields")
    func noEmptyFields() {
        let message = StillMapping.message("abc", .init(seen: true))
        #expect(message.fields.keys.sorted() == ["favorit", "gesehen"])
        #expect(StillMapping.titlePosition(from: message) == StateRecording.TitlePosition(seen: true))
    }

    /// CloudKit has no boolean values — they are stored as 0 and 1 in the field. That
    /// reading understands both is ``CloudSync/FieldValue``'s job; that we
    /// rely on it is stated here.
    @Test("Watched and favorite survive as a number")
    func truthAsNumber() {
        let message = CloudRecord(
            contentType: StillMapping.stillType, name: "abc",
            fields: ["gesehen": .integer(1), "favorit": .integer(0)])
        let location = StillMapping.titlePosition(from: message)
        #expect(location.seen)
        #expect(!location.favorite)
    }

    /// **An unknown kind is skipped and not deleted.** It comes from a
    /// newer program on the same account; whoever clears it takes the other device's
    /// state away.
    @Test("A foreign record kind does not disturb the state")
    func foreignKind() {
        var wordings = StillMapping.wordings(forItem: sample())
        wordings.append(
            CloudRecord(contentType: "Lesesitzung", name: "s1", fields: ["seiten": .integer(42)]))
        #expect(StillMapping.state(from: wordings) == sample())
    }

    /// The **profile's** settings (`name`, `color`, `kind`) live in the same
    /// record kind as those of the **state**. This mapping must not collect them.
    @Test("The profile's name and color do not end up in the state")
    func noProfileFields() {
        var wordings = StillMapping.wordings(forItem: sample())
        wordings += ProfileMapping.settings(
            forItem: Profile(identifier: .fresh(), name: "Max", color: .turquoise))
        #expect(StillMapping.state(from: wordings) == sample())
    }

    /// **The younger writer wins, not the larger value.** Whoever stops at
    /// 01:12:30 on the TV and chooses "start over" on the iPad should stay at 0.
    @Test("Start over really resets the position")
    func fromStart() {
        let tv = StillMapping.message(
            "f1", .init(location: 4350, duration: 7200), now: yesterday)
        let ipad = StillMapping.message(
            "f1", .init(location: 0, duration: 7200), now: yesterday.addingTimeInterval(3600))
        let merged = StillMapping.stillRule.merge(ipad, tv)
        #expect(StillMapping.titlePosition(from: merged).location == 0)

        // And the other way round: A device that was offline for a long time writes nothing back.
        let reversed = StillMapping.stillRule.merge(tv, ipad)
        #expect(StillMapping.titlePosition(from: reversed).location == 0)
    }

    @Test("An empty state yields no records")
    func empty() {
        #expect(StillMapping.wordings(forItem: StateRecording()).isEmpty)
        #expect(StillMapping.state(from: []) == StateRecording())
    }
}
