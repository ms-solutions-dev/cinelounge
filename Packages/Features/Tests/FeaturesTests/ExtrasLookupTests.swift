import Core
import Foundation
import PortalKit
import Testing

@testable import Features

/// The title extras of the detail column arrive only after the dwell time.
@MainActor
@Suite("Detail column: extras fetch")
struct ExtrasLookupTests {

    private func title(_ id: String) -> MediaItem { MediaItem(id: id, kind: .movie, title: id) }
    private let details = TitleExtras(label: "Studio Nord")

    @Test("Paging through sends no request")
    func pageThrough() async {
        var asked: [String] = []
        let fetch = ExtrasLookup(
            load: {
                asked.append($0.id); return nil
            },
            wait: { _ in try? await Task.sleep(for: .seconds(3600)) })

        fetch.focus(title("a"))
        fetch.focus(title("b"))
        fetch.focus(title("c"))
        fetch.stop()
        for _ in 0..<5 { await Task.yield() }

        #expect(asked.isEmpty)
        #expect(fetch.fund == nil)
    }

    @Test("Whoever stops gets the details — for their title")
    func standStill() async {
        let fetch = ExtrasLookup(load: { [details] _ in details }, wait: { _ in })

        fetch.focus(title("a"))
        await fetch.pending?.value

        #expect(fetch.fund == ExtrasLookup.Hit(itemID: "a", details: details))
    }

    @Test("What arrived once is not asked again — not even an empty result")
    func remembered() async {
        var asked: [String] = []
        let fetch = ExtrasLookup(
            load: { [details] item in
                asked.append(item.id)
                return item.id == "a" ? details : nil
            },
            wait: { _ in })

        for id in ["a", "b", "a", "b"] {
            fetch.focus(title(id))
            await fetch.pending?.value
        }

        #expect(asked == ["a", "b"])
        #expect(fetch.fund == nil)
        fetch.focus(title("a"))
        #expect(fetch.fund?.itemID == "a")
    }

    @Test("After a focus change the previous title's details are not shown")
    func focusChange() async {
        let fetch = ExtrasLookup(load: { [details] _ in details }, wait: { _ in })
        fetch.focus(title("a"))
        await fetch.pending?.value

        fetch.focus(title("neu"))

        #expect(fetch.fund == nil)
    }
}
