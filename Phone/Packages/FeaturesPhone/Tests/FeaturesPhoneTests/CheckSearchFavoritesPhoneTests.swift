import Core
import Flows
import Foundation
import Testing

@testable import FeaturesPhone

/// Check findings F2 and F3 on the phone: Favorites do not reload, a silent source becomes
/// "nothing remembered".
@MainActor
struct CheckSearchFavoritesPhoneTests {

    final class TallyCounter: @unchecked Sendable {
        var title: [String] = ["a"]
    }

    struct SwitchingSource: FavoritesSource {
        let counter: TallyCounter
        func favorites() async -> FavoritesBundle {
            FavoritesBundle(
                origin: .jellyfin, headline: .wording("M"),
                title: counter.title.map { TileContent(id: $0, title: $0) })
        }
    }

    struct FixedSource: FavoritesSource {
        let sharedStore: FavoritesBundle
        func favorites() async -> FavoritesBundle { sharedStore }
    }

    @Test("A new star appears on the next appearance (`.task` calls `load()`)")
    func loadOnAppear() async {
        let counter = TallyCounter()
        let model = FavoritesViewModel(sources: [SwitchingSource(counter: counter)])
        await model.load()
        counter.title = ["a", "b"]
        await model.load()  // that is how `.task` calls it on the second appearance
        #expect(model.filledBundles.first?.title.map(\.id) == ["a", "b"])
    }

    @Test("Jellyfin silent, channels empty: not \"nothing saved yet\"")
    func silentAndEmpty() async {
        let model = FavoritesViewModel(sources: [
            FixedSource(
                sharedStore: FavoritesBundle(
                    origin: .jellyfin, headline: .wording("M"), title: [],
                    hasAnswered: false)),
            FixedSource(
                sharedStore: FavoritesBundle(
                    origin: .channelList, headline: .wording("S"), title: [])),
        ])
        await model.load()
        // With istLeer && !keineAntwort the view shows the sentence "leerFavoriten" and
        // suppresses the hint rows of the silent sources.
        #expect(!(model.isEmpty && !model.noResponse))
        #expect(model.disruption == .networkJellyfin)
    }
}
