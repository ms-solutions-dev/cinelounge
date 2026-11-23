import Foundation
import Testing

@testable import PortalKit

/// Does the app read the new server — **with the bridge's models?**
///
/// **This is the check on which the whole switchover hangs.** The claim is: server and bridge answer in the
/// same shape and different words, and so a translation of the keys is enough. If it were wrong, it would
/// show here and nowhere else — until a screen stayed empty on the TV.
///
/// **The state and household recordings are real** (2026-09-12, home server). A rebuilt response would prove
/// only that someone rebuilt it the way he understands the server. The portal answers (`portals`, `menu`,
/// `list`, `suche`, `sources`) carry the server's exact shape — every key, the nulls included — but invented
/// titles and addresses: `intern/fixtures-synth/portals.py` writes them, so that no broadcaster's catalogue
/// ships with the tests.
@Suite("The CineLounge server, read with the bridge's models")
struct PortalServerTests {

    /// The same reader that ``PortalBridge`` builds for the server.
    private func reader() -> JSONDecoder {
        let reader = JSONDecoder()
        reader.keyDecodingStrategy = .custom { path in
            DialectKey(PortalDialect.cinelounge.key(path: path))
        }
        return reader
    }

    private func recording(_ name: String) throws -> Data {
        let folder = try #require(Bundle.module.url(forResource: "Mitschnitte", withExtension: nil))
        return try Data(contentsOf: folder.appendingPathComponent("\(name).json"))
    }

    @Test("The portal list")
    func portals() throws {
        let read = try reader().decode(
            BridgeReply.Portals.self, from: recording("portals"))
        #expect(read.portals.count == 3)

        let threeSat = try #require(read.portals.first { $0.id == "3sat" })
        #expect(threeSat.name == "3sat")
        #expect(threeSat.kind == "native")
        // `ready` instead of `ready` — the state is a value, not a key.
        #expect(threeSat.isReady)
        #expect(threeSat.adult == false)
        #expect(threeSat.network == "direct")
        #expect(threeSat.description?.isEmpty == false)
        #expect(threeSat.can(.paging))
        #expect(threeSat.can(.ownImages))
        #expect(threeSat.can(.seasons) == false)

        // An 18+ portal is in the list; it is hidden at the server, not here.
        let hideout = try #require(read.portals.first { $0.adult == true })
        #expect(hideout.kind == "extension-foreign")
    }

    @Test("The entry window")
    func menu() throws {
        let read = try reader().decode(BridgeReply.Menu.self, from: recording("menu"))
        #expect(read.portal == "zdf")
        let first = try #require(read.entries.first)
        #expect(first.id == "neu")
        #expect(first.group == "curated")
        // `count: null` means **unknown** and not 0.
        #expect(first.count == nil)
        #expect(first.character == "🆕")
    }

    /// 2026-09-29: the CL-Server passes the TMDb identifier along, and it ends up on the title.
    @Test("The TMDb identifier arrives at the title")
    func tmdbIdentifier() throws {
        let raw = Data(
            #"""
            {"portal": "serieshub", "items": [{"title": "Stepbrook", "address": "a",
             "kind": "series", "key": "serieshub:stepbrook", "languages": [],
             "has_children": true, "tmdb_id": "tv/278514", "rating": 7.1}]}
            """#.utf8)
        let read = try reader().decode(BridgeReply.Page.self, from: raw)
        let title = try #require(read.items.first).asMediaItem(portal: "serieshub")
        #expect(title.ratings.tmdbID == "tv/278514")
        #expect(title.ratings.community == 7.1)
    }

    @Test("A list")
    func list() throws {
        let read = try reader().decode(BridgeReply.Page.self, from: recording("list"))
        #expect(read.portal == "ard")
        // `next` is a string, not a counter — it is returned.
        #expect(read.next != nil)
        #expect(read.needsInput == nil)

        let first = try #require(read.items.first)
        #expect(first.title.isEmpty == false)
        #expect(first.key.contains(":"))
        #expect(first.address.isEmpty == false)
    }

    /// Without `show` a hit list is not readable — shown on 2026-09-11.
    @Test("The series above the title")
    func rowAboveTitle() throws {
        let read = try reader().decode(BridgeReply.Search.self, from: recording("suche"))
        let match = try #require(read.match["ard"])
        let episode = try #require(match.first { $0.row != nil })
        #expect(episode.row == "Das Moorrevier")
        #expect(episode.title.contains("Folge"))
    }

    /// **The error that would have cost a whole list.** Without a known duration the server sends
    /// `"fraction": null` and `"remaining_s": null`; `portion` was a non-optional `Double` here, and such a
    /// response broke off while reading — not that one state, but the list it was in. For portal scripts a title
    /// without a runtime is the normal case.
    ///
    /// Plus the vocabulary word that looked too similar to stand out: the server writes `duration_s`, the
    /// bridge `dauer_s`. Without translation the duration would be missing in `/state`, `/resume` and
    /// `/favorites` — that is, everywhere the bar comes from.
    @Test("A state without a known duration")
    func progressWithoutDuration() throws {
        let row = try reader().decode(
            BridgeReply.ProgressRow.self, from: recording("stand-ohne-dauer"))
        #expect(row.key == "zdf:vokabelprobe:2026")
        #expect(row.positionSeconds == 99)
        #expect(row.durationSeconds == 0)
        // Unknown, and therefore not zero percent.
        #expect(row.portion == nil)
        #expect(row.remainingSeconds == nil)
    }

    @Test("A complete state")
    func progressFull() throws {
        let row = try reader().decode(
            BridgeReply.ProgressRow.self, from: recording("stand-voll"))
        #expect(row.portal == "zdf")
        #expect(row.title == "Vokabelprobe")
        #expect(row.positionSeconds == 42)
        #expect(row.durationSeconds == 3000)
        #expect(row.portion == 0.014)
        #expect(row.remainingSeconds == 2958)
        #expect(row.favorite)
    }

    @Test("The hosts of an episode")
    func sources() throws {
        let read = try reader().decode(BridgeReply.Sources.self, from: recording("sources"))
        #expect(read.portal == "zdf")
        let first = try #require(read.sources.first)
        #expect(first.name.isEmpty == false)
        // A blocked host is displayed and greyed out, not omitted — otherwise a portal with six dead hosts looks
        // like one without sources.
        #expect(first.locked == false)
    }
}

/// What goes from `/play` to the player.
@Suite("The playback route")
struct PortalStreamTests {

    private func track(
        _ language: String, _ format: String, _ address: String
    )
        -> BridgeReply.SubtitleTrack
    {
        let raw = """
            {"sprache":"\(language)","format":"\(format)","adresse":"\(address)"}
            """
        return try! JSONDecoder().decode(
            BridgeReply.SubtitleTrack.self, from: Data(raw.utf8))
    }

    /// **Only WebVTT goes out.** AVPlayer does not open EBU-TT-D, and a subtitle that does not open is worse
    /// than none.
    @Test("Only WebVTT gets through")
    func webVTTOnly() {
        #expect(PortalSubtitle(track("deu", "vtt", "https://x/a.vtt")) != nil)
        #expect(PortalSubtitle(track("deu", "VTT", "https://x/a.vtt")) != nil)
        #expect(PortalSubtitle(track("deu", "ttml", "https://x/a.xml")) == nil)
        // Without a scheme the address cannot be fetched — `URL(string:)` accepts it anyway.
        #expect(PortalSubtitle(track("deu", "vtt", "kein URL")) == nil)
        #expect(PortalSubtitle(track("deu", "vtt", "/pfad/ohne/schema.vtt")) == nil)
    }

    /// The code stays as the portal names it — often three letters.
    @Test("The language code is not reshaped")
    func languageCodeStays() throws {
        let track = try #require(PortalSubtitle(track("deu", "vtt", "https://x/a.vtt")))
        #expect(track.language == "deu")
    }

    /// **Empty means "this portal supplies none", not "not loaded yet".**
    @Test("A stream without subtitles carries an empty list")
    func emptyList() throws {
        let stream = PortalStream(
            address: try #require(URL(string: "http://x/stream")), validUntil: nil,
            headers: [:], subtitles: [])
        #expect(stream.subtitles.isEmpty)
    }
}

/// What a portal row says about its portal.
@Suite("The portal row")
struct PortalRowTests {

    /// **No `if portal ==` — the capability is queried**, and it knows both words.
    @Test("Capabilities in both vocabularies")
    func capabilities() {
        let server = PortalRow(
            id: "ahorn", name: "AHORN", capabilities: ["own_images", "paging", "seasons"])
        let bridge = PortalRow(
            id: "ahorn", name: "AHORN", capabilities: ["eigene_bilder", "blaettern", "staffeln"])
        for row in [server, bridge] {
            #expect(row.can(.seasons))
            #expect(row.can(.paging))
            #expect(row.can(.ownImages))
            #expect(row.can(.resolver) == false)
        }
    }

    /// **A media library before a portal script.** A statement about origin, not about quality — and it pays off on
    /// the day a portal script breaks.
    @Test("Official is what a channel interface speaks")
    func official() {
        #expect(PortalRow(id: "ahorn", name: "AHORN", kind: "native").isOfficial)
        // `own` is the bridge's word for the same.
        #expect(PortalRow(id: "ahorn", name: "AHORN", kind: "eigen").isOfficial)
        #expect(PortalRow(id: "animehub", name: "Animehub", kind: "extension").isOfficial == false)
        #expect(
            PortalRow(id: "probe", name: "Probe", kind: "extension-foreign").isOfficial == false)
    }

    /// The defaults describe the old bridge: no sentence, no limits, nothing 18+.
    @Test("Without details the bridge's situation applies")
    func parameters() {
        let row = PortalRow(id: "x", name: "X")
        #expect(row.description.isEmpty)
        #expect(row.limits.isEmpty)
        #expect(row.adult == false)
        #expect(row.network == "direct")
        #expect(row.ready)
    }
}
