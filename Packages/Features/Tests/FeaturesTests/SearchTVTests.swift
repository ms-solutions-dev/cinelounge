import Core
import Flows
import Foundation
import Testing

@testable import Features

/// **Search on the TV runs the shared flow** (AP58 R6, St4).
///
/// Until then an error of the media server aborted the whole search; the provider's hits,
/// which had long since arrived, vanished behind a fault. Now the phone
/// behavior applies: only the group goes silent.
@MainActor
struct SearchTVTests {

    typealias Group = SearchModel.ResultGroup

    static func source(
        _ origin: Origin, _ ids: [String], responds: Bool = true
    )
        -> Search<Group>.Source
    {
        { _, _ in
            Group(
                origin: origin,
                match: ids.map { MediaItem(id: $0, kind: .movie, title: $0) },
                hasAnswered: responds)
        }
    }

    static func needle(_ model: SearchModel, _ word: String) async {
        model.termChanged(to: word)
        await model.search.running?.value
    }

    @Test("A silent media server does not take the provider hits down with it")
    func silentServer() async {
        let model = SearchModel(sources: [
            Self.source(.jellyfin, [], responds: false), Self.source(.provider, ["a1"]),
        ])
        await Self.needle(model, "drugladan")
        #expect(
            model.state
                == .results(groups: [
                    Group(
                        origin: .provider,
                        match: [
                            MediaItem(id: "a1", kind: .movie, title: "a1")
                        ])
                ]))
        #expect(model.vodIDs == ["a1"])
    }

    @Test("If nobody answers it is a failure, not “nothing found”")
    func allSilent() async {
        let model = SearchModel(sources: [Self.source(.jellyfin, [], responds: false)])
        await Self.needle(model, "drugladan")
        guard case .failed = model.state else {
            Issue.record("expected: failure, was \(model.state)")
            return
        }
    }

    @Test("Searched, answered, nothing found")
    func nothingFound() async {
        let model = SearchModel(sources: [Self.source(.jellyfin, [])])
        await Self.needle(model, " drugladan ")
        #expect(model.state == .empty("drugladan"))
        model.clear()
        #expect(model.state == .idle)
    }

    @Test("Wait time and hit count are the shared ones")
    func limits() {
        #expect(Search<Group>.waitTime == .milliseconds(350))
        #expect(Search<Group>.perGroup == 20)
    }
}
