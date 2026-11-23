import Core
import Flows
import Foundation
import Testing

/// **The header-area ladder, shared** (decision 27, C4) — steps and follow-up question.
struct HeroLadderTests {

    actor Transcript {
        private(set) var entries: [String] = []
        func write(_ entry: String) { entries.append(entry) }
    }

    @Test("Loaded before lookup, then channel list, otherwise set up")
    func slots() {
        #expect(
            HeroLadder.tier(loaded: ["a"], lookup: ["b"], leadsWithChannelList: true) == .title(["a"]))
        #expect(
            HeroLadder.tier(loaded: [String](), lookup: ["b"], leadsWithChannelList: true)
                == .title(["b"]))
        #expect(HeroLadder.tier(loaded: [String](), leadsWithChannelList: true) == .nowOnAir)
        #expect(HeroLadder.tier(loaded: [String](), leadsWithChannelList: false) == .setUp)
        #expect(HeroLadder.Tier<String>.nowOnAir.heroes.isEmpty)
    }

    @Test("The lookup takes only titles with an image and asks at most twice as often")
    func lookup() async {
        let candidates = (1...10).map { "t\($0)" }
        let asked = Transcript()
        let found = await HeroLadder.lookup(
            candidates: candidates, atMost: 2, shuffle: false
        ) { identifier in
            await asked.write(identifier)
            var title = MediaItem(id: identifier, kind: .movie, title: identifier)
            if identifier == "t3" || identifier == "t4" { title.artwork.backdropID = "b" }
            return title
        }
        #expect(found.map(\.id) == ["t3", "t4"])
        #expect(await asked.entries == ["t1", "t2", "t3", "t4"])

        let withoutImage = await HeroLadder.lookup(
            candidates: candidates, atMost: 2, shuffle: false
        ) { MediaItem(id: $0, kind: .movie, title: $0) }
        #expect(withoutImage.isEmpty)
    }
}
