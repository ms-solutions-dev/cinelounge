import CloudSync
import Core
import Foundation
import Testing

@testable import ProfileKit

/// Channel lists as records — the only kind with an encrypted field.
@Suite("Channel lists as records")
struct ChannelListMappingTests {

    let panel = URL(string: "http://panel.example:8080")!
    let m3u = URL(string: "http://listen.example/get.php?username=max&password=geheim&type=m3u")!

    func xtream() -> ChannelListAccess {
        ChannelListAccess(
            key: "xtream|panel.example|max", name: "Anbieter", kind: .xtream,
            address: panel, user: "max",
            epg: URL(string: "http://panel.example:8080/xmltv.php"), active: true,
            secret: "geheim")
    }

    @Test("Round trip loses nothing")
    func roundTrip() {
        let list = xtream()
        let back = ChannelListMapping.listen(
            from: [ChannelListMapping.message(forItem: list)])
        #expect(back == [list])
    }

    /// **The password lives in exactly one field, and that one is encrypted.**
    ///
    /// An existing field cannot be encrypted retroactively, and containers
    /// are never deleted — whoever first creates it in plain text later needs a second
    /// field, and the first stays next to it forever.
    @Test("Only the secret is encrypted")
    func isSecret() {
        let message = ChannelListMapping.message(forItem: xtream())
        #expect(message.encrypted == ["geheimnis"])
        #expect(message["geheimnis"]?.text == "geheim")
        // Everything else is open — and none of it carries a secret.
        let pending = Set(message.fields.keys).subtracting(message.encrypted)
        #expect(pending == ["name", "art", "adresse", "benutzer", "epg", "aktiv"])
        for field in pending {
            #expect(message[field]?.text?.contains("geheim") != true, "\(field)")
        }
    }

    /// **An M3U address carries the password as a query parameter.** Storing it in plain text
    /// would mean storing the password in plain text — the same reasoning as at
    /// ``Core/ListKey``, only that the key now really goes to iCloud.
    @Test("The open address carries no query part")
    func openAddress() {
        let without = ChannelListAccess.pending(m3u)
        #expect(without.absoluteString == "http://listen.example/get.php")
        #expect(!without.absoluteString.contains("password"))

        let list = ChannelListAccess(
            key: "m3u|listen.example|max", name: "Liste", kind: .m3u,
            address: without, user: "max", secret: m3u.absoluteString)
        let message = ChannelListMapping.message(forItem: list)
        #expect(message["adresse"]?.text?.contains("password") != true)
        #expect(message["geheimnis"]?.text == m3u.absoluteString)
        #expect(message.encrypted.contains("geheimnis"))
    }

    /// **Without a field, "enabled" applies.** A list that would silently be off
    /// after the reconciliation looks like a vanished login.
    @Test("A list without a switch is on")
    func withoutSwitch() {
        let message = CloudRecord(
            contentType: ChannelListMapping.contentType, name: "xtream|a|b", fields: ["art": .text("xtream")])
        #expect(ChannelListMapping.list(from: message)?.active == true)
    }

    /// **What the kind does not know is not guessed.** A half-read channel list
    /// would be an entry that looks like a login and is none — and the viewer
    /// looks for the error at the provider.
    @Test("An unknown kind yields no list")
    func unknownKind() {
        let message = CloudRecord(
            contentType: ChannelListMapping.contentType, name: "stalker|a|b",
            fields: ["art": .text("stalker"), "name": .text("Irgendwas")])
        #expect(ChannelListMapping.list(from: message) == nil)
        #expect(ChannelListMapping.listen(from: [message]).isEmpty)
    }

    @Test("An access without a secret stays without a field")
    func withoutSecret() {
        let list = ChannelListAccess(
            key: "jellyfin", name: "Medienserver", kind: .jellyfin)
        let message = ChannelListMapping.message(forItem: list)
        #expect(message["geheimnis"] == nil)
        #expect(ChannelListMapping.list(from: message) == list)
    }

    /// The record name **is** the list key from AP42 — the same on two devices,
    /// otherwise there would be duplicates instead of conflicts.
    @Test("The record name is the list key")
    func name() {
        #expect(ChannelListMapping.message(forItem: xtream()).name == "xtream|panel.example|max")
    }
}
