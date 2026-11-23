import Core
import Foundation
import Testing

@testable import PlaylistKit

/// Tested against what such parsers fail on in reality.
///
/// The most common complaint about comparable apps is not a missing feature
/// but: "my list is not being read". Foreign lists are messy, and
/// edge cases are the normal case here — every case below comes from a real
/// list or from a known generator.
@Suite("Parsing M3U")
struct M3UParserTests {

    // MARK: - Der Normalfall

    @Test("An ordinary entry is read completely")
    func standardEntry() throws {
        let text = """
            #EXTM3U
            #EXTINF:-1 tvg-id="ahorn.de" tvg-logo="http://logo/ahorn.png" group-title="DE · Öffentlich",Das Nordlicht HD
            http://server/live/1.ts
            """

        let channels = M3UParser.parse(text, playlistID: "liste")
        let first = try #require(channels.first)

        #expect(channels.count == 1)
        #expect(first.name == "Das Nordlicht HD")
        #expect(first.group == "DE · Öffentlich")
        #expect(first.epgID == "ahorn.de")
        #expect(first.logoURL?.absoluteString == "http://logo/ahorn.png")
        #expect(first.streamURL.absoluteString == "http://server/live/1.ts")
        #expect(first.playlistID == "liste")
    }

    @Test("The order of the attributes does not matter")
    func attributeOrder() throws {
        // No generator keeps a fixed order.
        let a = """
            #EXTINF:-1 tvg-id="x" group-title="G" tvg-logo="http://l/1.png",Sender
            http://s/1
            """
        let b = """
            #EXTINF:-1 tvg-logo="http://l/1.png" tvg-id="x" group-title="G",Sender
            http://s/1
            """

        let first = try #require(M3UParser.parse(a).first)
        let second = try #require(M3UParser.parse(b).first)

        #expect(first.group == second.group)
        #expect(first.epgID == second.epgID)
        #expect(first.logoURL == second.logoURL)
    }

    // MARK: - Wo es bricht

    @Test("A comma in the group name does not cut the channel name")
    func commaInsideAttribute() throws {
        // The classic mistake: splitting at the **first** comma. Then the
        // channel is named " national\" " instead of "Sola Sport 1".
        let text = """
            #EXTINF:-1 group-title="Sport, national",Sola Sport 1
            http://s/1
            """

        let channel = try #require(M3UParser.parse(text).first)

        #expect(channel.name == "Sola Sport 1")
        #expect(channel.group == "Sport, national")
    }

    @Test("Values without quotation marks are read as well")
    func unquotedValues() throws {
        let text = """
            #EXTINF:-1 tvg-id=ahorn.de group-title=Öffentlich,Das Nordlicht
            http://s/1
            """

        let channel = try #require(M3UParser.parse(text).first)

        #expect(channel.epgID == "ahorn.de")
        #expect(channel.group == "Öffentlich")
    }

    @Test("The group may also stand on a line of its own")
    func extgrpLine() throws {
        // An older notation that some generators use to this day.
        let text = """
            #EXTINF:-1,Sender A
            #EXTGRP:Nachrichten
            http://s/1
            """

        let channel = try #require(M3UParser.parse(text).first)

        #expect(channel.group == "Nachrichten")
    }

    @Test("A group in the info line beats the separate line")
    func groupTitleWins() throws {
        // Both at once occur. The marker line is the newer and more precise
        // value.
        let text = """
            #EXTINF:-1 group-title="Aus der Kennzeile",Sender
            #EXTGRP:Aus der eigenen Zeile
            http://s/1
            """

        #expect(M3UParser.parse(text).first?.group == "Aus der Kennzeile")
    }

    @Test("Lines of foreign origin do not break the entry")
    func unknownDirectives() throws {
        // `#EXTVLCOPT` sits between marker line and address and does not belong to the
        // channel. Whoever aborts there loses every second entry.
        let text = """
            #EXTINF:-1 group-title="G",Sender
            #EXTVLCOPT:http-user-agent=VLC/3.0
            #EXTVLCOPT:network-caching=1000
            http://s/1
            """

        let channel = try #require(M3UParser.parse(text).first)

        #expect(channel.name == "Sender")
        #expect(channel.streamURL.absoluteString == "http://s/1")
    }

    @Test("A byte order mark at the start does not disturb")
    func byteOrderMark() {
        // It is invisible and sticks to the first `#EXTM3U`. With it the
        // first line is not recognised — and with some lists that is the only one.
        let text = "\u{FEFF}#EXTM3U\n#EXTINF:-1,Sender\nhttp://s/1"

        #expect(M3UParser.parse(text).count == 1)
    }

    @Test("Windows line endings are read")
    func windowsLineEndings() {
        let text = "#EXTM3U\r\n#EXTINF:-1,Sender\r\nhttp://s/1\r\n"

        #expect(M3UParser.parse(text).count == 1)
    }

    @Test("An entry without an address lapses, the next one comes anyway")
    func entryWithoutURL() throws {
        // Occurs at the end of a file when a fetch was aborted. Without this
        // behaviour the aborted entry would take over the address of the next one.
        let text = """
            #EXTINF:-1,Abgebrochener Sender
            #EXTINF:-1,Vollständiger Sender
            http://s/2
            """

        let channels = M3UParser.parse(text)

        #expect(channels.count == 1)
        #expect(channels.first?.name == "Vollständiger Sender")
        #expect(channels.first?.streamURL.absoluteString == "http://s/2")
    }

    @Test("Entries without a usable address are skipped")
    func invalidURL() {
        let text = """
            #EXTINF:-1,Kaputt
            nicht-mal-eine-adresse
            #EXTINF:-1,Gut
            http://s/2
            """

        let channels = M3UParser.parse(text)

        #expect(channels.map(\.name) == ["Gut"])
    }

    @Test("An entry without a name falls back to tvg-name")
    func nameFromAttribute() throws {
        let text = """
            #EXTINF:-1 tvg-name="Aus dem Attribut",
            http://s/1
            """

        #expect(M3UParser.parse(text).first?.name == "Aus dem Attribut")
    }

    @Test("Without any name the entry is discarded")
    func noNameAtAll() {
        // A nameless channel cannot be found in a list of four hundred —
        // it would just be an empty row.
        #expect(M3UParser.parse("#EXTINF:-1,\nhttp://s/1").isEmpty)
    }

    // MARK: - Doppelte

    @Test("The same channel with the same address comes only once")
    func exactDuplicates() {
        // The normal case in merged lists.
        let text = """
            #EXTINF:-1,Das Nordlicht HD
            http://s/1
            #EXTINF:-1,Das Nordlicht HD
            http://s/1
            """

        #expect(M3UParser.parse(text).count == 1)
    }

    @Test("Same name, different address is kept")
    func sameNameDifferentSource() {
        // Usually two resolutions of the same channel. Keeping both is
        // right — you want the choice when one stutters.
        let text = """
            #EXTINF:-1,Das Nordlicht (1080p)
            http://s/hd
            #EXTINF:-1,Das Nordlicht (576p)
            http://s/sd
            """

        #expect(M3UParser.parse(text).count == 2)
    }

    @Test("The resolution in the name is removed for display")
    func cleanName() {
        let channel = M3UParser.parse("#EXTINF:-1,Das Nordlicht (1080p)\nhttp://s/1").first

        #expect(channel?.name == "Das Nordlicht (1080p)", "the raw name is kept")
        #expect(channel?.cleanName == "Das Nordlicht", "for the eye without resolution")
    }

    @Test("Every channel gets an identifier of its own")
    func uniqueIdentifiers() {
        // Two entries with the same ID are shown by the display as one, and the
        // focus jumps while scrolling.
        let text = """
            #EXTINF:-1,Sender
            http://s/1
            #EXTINF:-1,Sender
            http://s/2
            """

        let ids = M3UParser.parse(text, playlistID: "l").map(\.id)

        #expect(Set(ids).count == ids.count)
    }

    // MARK: - Umfang

    @Test("An empty or nonsensical file yields nothing instead of failing")
    func emptyInput() {
        #expect(M3UParser.parse("").isEmpty)
        #expect(M3UParser.parse("#EXTM3U").isEmpty)
        #expect(M3UParser.parse("völliger Unsinn ohne Aufbau").isEmpty)
    }

    @Test("A list with four hundred channels is read completely")
    func largeList() {
        // The real list has 401 entries. The test pins down that nothing
        // gets lost along the way — with stateful parsers that is exactly what happens.
        let entries = (1...400).map { index in
            """
            #EXTINF:-1 tvg-id="s\(index)" group-title="Gruppe \(index % 12)",Sender \(index)
            http://server/live/\(index).ts
            """
        }
        let text = (["#EXTM3U"] + entries).joined(separator: "\n")

        let channels = M3UParser.parse(text, playlistID: "gross")

        #expect(channels.count == 400)
        #expect(Set(channels.map(\.group)).count == 12)
        #expect(Set(channels.map(\.id)).count == 400)
    }
}
