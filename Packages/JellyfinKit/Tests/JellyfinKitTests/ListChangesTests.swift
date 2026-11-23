import Core
import Foundation
import Testing

@testable import JellyfinKit

/// The wire every refresh hangs on.
///
/// **Why these checks exist (finding 2026-08-13).** Viewer report: "When I start a film and
/// leave it again, the detail page does not notice that it is running — only when I go
/// out and come back in does it say 'Continue Watching'." The same on the Home screen:
/// anything started did not show up on the shelf.
///
/// The search went on in the wrong place for a long time — at discarding the cache, at the
/// order of the messages to the server. The wire was simply not connected: ``ContentSource``
/// carried a convenient default for ``ContentSource/listChanges()`` ("a stream that never
/// reports anything"), and ``JellyfinSource`` wrote its own answer **without** `async`. That
/// left two candidates to choose from at every call site, and whoever held the source as a
/// concrete type — Home, detail page, shell — got the default: a stream that ends
/// immediately. No error, no message, just silence.
///
/// The default has therefore disappeared from the contract. These checks pin that down,
/// **and over both paths**: one path alone would not have found the error — through
/// `any ContentSource` it worked the whole time.
@Suite("The stream comes from the source")
struct ListChangesTests {

    static func makeSource() -> JellyfinSource {
        JellyfinSource(
            credentials: ServerCredentials(
                serverURL: URL(string: "https://example.invalid")!,
                userID: "pruefnutzer",
                username: "pruefnutzer",
                accessToken: "not-a-real-key"
            ),
            deviceID: "check-device"
        )
    }

    /// Listen first, then trigger, then read — in this order.
    ///
    /// The stream holds the latest message (`bufferingNewest(1)`), so reading may come
    /// afterward. The other way round — read first, then trigger — the check would hang forever
    /// on a silent stream instead of failing.
    static func reportsIn(_ stream: AsyncStream<Void>) async -> Bool {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() != nil
    }

    @Test("On the concrete type the stream reports after a playback")
    func concreteTypeReceivesNotification() async {
        let source = Self.makeSource()

        // Exactly as it stands in ``DetailModel``, ``HomeModel`` and ``MainView``: the source as
        // `JellyfinSource`, not as a contract. That is the line that silently ran into nothing.
        let changes = await source.listChanges()
        await source.refreshAfterPlayback(ids: ["film-1"])

        #expect(await Self.reportsIn(changes), "the detail page would otherwise listen on a dead wire")
    }

    @Test("Seen through the contract the same stream reports")
    func protocolTypeReceivesNotification() async {
        let source: any ContentSource = Self.makeSource()

        let changes = await source.listChanges()
        await source.refreshAfterPlayback(ids: ["film-1"])

        #expect(await Self.reportsIn(changes))
    }

    @Test("Two listeners get the same message")
    func everyObserverIsNotified() async {
        let source = Self.makeSource()

        // The app always has several: the shell, the Home shelf, the library, the open detail
        // page. A stream that only serves the most recently subscribed one would look like
        // "sometimes it works, sometimes it doesn't" in everyday use.
        let first = await source.listChanges()
        let second = await source.listChanges()
        await source.refreshAfterPlayback(ids: ["folge-7", "serie-1"])

        #expect(await Self.reportsIn(first))
        #expect(await Self.reportsIn(second))
    }
}
