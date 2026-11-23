import Foundation
import Testing

@testable import PortalKit

@Suite("The connection to the bridge")
struct PortalBridgeTests {

    /// "does not work" is no information. In `detail` the bridge names the reason the portal gave — that
    /// belongs on the TV.
    @Test("The reason is taken from the response")
    func reasonFromDetail() {
        let raw = Data(#"{"detail":"API-Schlüssel ist nicht gesetzt"}"#.utf8)
        #expect(PortalBridge.reason(from: raw) == "API-Schlüssel ist nicht gesetzt")
    }

    @Test("Without a readable reason, at least the status is named")
    func reasonWithoutDetail() {
        #expect(PortalBridge.reason(from: Data("kein JSON".utf8)) == nil)
        let withoutReason = PortalBridge.rejection(from: Data("kein JSON".utf8), status: 503)
        #expect(withoutReason.sentenceKey == "error.portal.rejected")
        #expect(withoutReason.message { _ in "abgelehnt ({status})" } == "abgelehnt (503)")
    }

    /// The server's refusal is a code and not a sentence — and the code has to get through.
    @Test("A rejection from the server keeps its code")
    func rejectionWithCode() throws {
        let raw = Data(#"{"error":{"code":"stream.geo_blocked","values":{"country":"DE"}}}"#.utf8)
        let error = PortalBridge.rejection(from: raw, status: 451)
        #expect(error.code == "stream.geo_blocked")
        guard case .cancelled(_, _, let values) = error else { Issue.record("no code"); return }
        #expect(values["country"] == "DE")
    }

    /// The bridge keeps answering with `detail` — and must keep being read.
    @Test("A rejection from the bridge stays a text")
    func rejectionWithText() {
        let raw = Data(#"{"detail":"API-Schlüssel ist nicht gesetzt"}"#.utf8)
        let error = PortalBridge.rejection(from: raw, status: 502)
        #expect(error.code == nil)
        #expect(error.errorDescription == "API-Schlüssel ist nicht gesetzt")
    }
}

@Suite("The dialect of the two services")
struct PortalDialectTests {

    @Test("For the bridge the translation changes nothing")
    func bridgeStays() {
        #expect(PortalDialect.bridge.route("portale") == "portale")
        #expect(PortalDialect.bridge.route("p/ahorn/liste") == "p/ahorn/liste")
        #expect(PortalDialect.bridge.asks(["einstieg": "neu"]) == ["einstieg": "neu"])
    }

    /// Only the last segment is translated: the portal name in the middle is a name.
    @Test("With the server only the last path segment is translated")
    func serverPaths() {
        #expect(PortalDialect.cinelounge.route("portale") == "portals")
        #expect(PortalDialect.cinelounge.route("p/ahorn/liste") == "p/ahorn/list")
        #expect(PortalDialect.cinelounge.route("p/liste/kinder") == "p/liste/children")
        #expect(PortalDialect.cinelounge.route("p/ahorn/menu") == "p/ahorn/menu")
    }

    @Test("Query parts the server does not know are dropped")
    func serverQueries() {
        let asked = PortalDialect.cinelounge.asks(
            ["einstieg": "neu", "weiter": "2", "weiterleiten": "false"])
        #expect(asked == ["entry": "neu", "next": "2"])
    }

    /// `state` means two things at the server — and the bridge kept them apart.
    @Test("state is the status in the portal and the watch state in the entry")
    func stateIsTwoThings() {
        let inPortal = [DialectKey("portals"), DialectKey("state")]
        let inEntry = [DialectKey("items"), DialectKey("state")]
        #expect(PortalDialect.cinelounge.key(path: inPortal) == "zustand")
        #expect(PortalDialect.cinelounge.key(path: inEntry) == "stand")
    }

    @Test("The way back reverses the same table")
    func outbound() {
        #expect(PortalDialect.cinelounge.outgoingKey(path: [DialectKey("schluessel")]) == "key")
        #expect(PortalDialect.cinelounge.outgoingKey(path: [DialectKey("gesehen")]) == "watched")
        #expect(
            PortalDialect.bridge.outgoingKey(path: [DialectKey("schluessel")]) == "schluessel")
    }
}

@Suite("The capabilities of a portal")
struct PortalCapabilityTests {

    /// The bridge writes them in German, the server in English — both must count.
    @Test("Both words mean the same capability")
    func bothWords() {
        #expect(PortalCapability.seasons.settled(in: ["staffeln", "suche"]))
        #expect(PortalCapability.seasons.settled(in: ["seasons", "search"]))
        #expect(PortalCapability.seasons.settled(in: ["search"]) == false)
        #expect(PortalCapability(word: "own_images") == .ownImages)
        #expect(PortalCapability(word: "eigene_bilder") == .ownImages)
    }

    /// The server may be able to do more than this app serves.
    @Test("An unknown word is not an error")
    func unknownWord() {
        #expect(PortalCapability(word: "zeitreise") == nil)
    }
}
