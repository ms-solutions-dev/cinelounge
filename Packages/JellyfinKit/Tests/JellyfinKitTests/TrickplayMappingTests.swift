import Core
import Foundation
import JellyfinAPI
import Testing

@testable import JellyfinKit

/// The translation of the scrubbing preview is the place with the most silent traps: the
/// server nests twice, reports milliseconds instead of seconds and calls a count "Width". Each
/// of these points leads to a preview that shows something — just the wrong thing. A crash
/// would be easier to find.
///
/// The basis is a real server response to
/// `Users/{userID}/Items/{itemID}?Fields=Trickplay` for the first episode of "Skeblus deitseflaum
/// Poblaplal", fetched with `curl` and shortened only by uninvolved fields.
@Suite("Scrub preview")
struct TrickplayMappingTests {

    static let serverURL = URL(string: "http://192.0.2.44:8096")!
    static let itemID = "4f7a85536b68adcaa65defef27c8ce98"

    static func decode(_ json: String) throws -> BaseItemDto {
        // The same decoder as in the real integration — otherwise the test checks something other
        // than what runs later.
        try JellyfinDecoder.make().decode(BaseItemDto.self, from: Data(json.utf8))
    }

    static func trickplay(_ json: String) throws -> Trickplay? {
        ItemMapping.trickplay(from: try decode(json), serverURL: serverURL, accessToken: "token")
    }

    /// Unchanged, as the server delivers it.
    static let withTrickplay = """
        {
          "Name": "Für dich in 2000 Wintern - Der Fall von Kerrbach, Teil 1",
          "Id": "4f7a85536b68adcaa65defef27c8ce98",
          "Type": "Episode",
          "RunTimeTicks": 15400390000,
          "Trickplay": {
            "4f7a85536b68adcaa65defef27c8ce98": {
              "320": {
                "Width": 320,
                "Height": 180,
                "TileWidth": 10,
                "TileHeight": 10,
                "ThumbnailCount": 154,
                "Interval": 10000,
                "Bandwidth": 11539
              }
            }
          }
        }
        """

    @Test("The server's nested values are read completely")
    func mapsRealResponse() throws {
        let trickplay = try #require(try Self.trickplay(Self.withTrickplay))

        #expect(trickplay.width == 320)
        #expect(trickplay.height == 180)
        // `TileWidth` and `TileHeight` count preview images per row and column, not pixels — the
        // name suggests the opposite. Read as an edge length it would yield a grid of 320 × 180
        // cells, and no image would ever be seen.
        #expect(trickplay.tileColumns == 10)
        #expect(trickplay.tileRows == 10)
        #expect(trickplay.perSheet == 100)
        #expect(trickplay.thumbnailCount == 154)
    }

    @Test("The interval comes in milliseconds and is converted to seconds")
    func intervalConvertedToSeconds() throws {
        // `"Interval": 10000` is ten seconds. If the number stayed as it is, the first preview image
        // would lie at second ten thousand — that is, beyond the end of any episode, and the same
        // picture would be seen throughout while scrubbing.
        let trickplay = try #require(try Self.trickplay(Self.withTrickplay))

        #expect(trickplay.interval == 10)
        #expect(trickplay.thumbnailIndex(at: 95) == 9, "the tenth image")
        // 154 images at 100 per sheet: the image at 20:00 lies on the second.
        #expect(trickplay.sheetIndex(forThumbnail: trickplay.thumbnailIndex(at: 1200)) == 1)
    }

    @Test("The sheet URL can be extended by the sheet number")
    func sheetBaseAcceptsTheSheetNumber() throws {
        let trickplay = try #require(try Self.trickplay(Self.withTrickplay))

        // Checked against the server: `/Videos/{id}/Trickplay/320/0.jpg` delivers the image,
        // `/Items/{id}/Trickplay/320/0.jpg` answers with 404.
        #expect(
            trickplay.sheetBase.absoluteString
                == "http://192.0.2.44:8096/Videos/\(Self.itemID)/Trickplay/320?api_key=token"
        )
        // The access token must be in the address and must not be expected in a header: the sheets
        // are fetched by the image loader, which sends no sign-in along, and unlike with posters the
        // server answers here with 401 instead of handing out the image. It must not get lost when
        // the sheet number is appended — otherwise the preview stays empty.
        let sheet = trickplay.sheetURL(at: 1200)
        #expect(sheet.path == "/Videos/\(Self.itemID)/Trickplay/320/1.jpg")
        #expect(sheet.query == "api_key=token")
    }

    @Test("Without a generated preview nothing comes back")
    func absentTrickplay() throws {
        // The server generates the sheets only if it is set up for it, and then delivers the field as
        // an **empty object** instead of omitting it — the local trailer in the catalog is exactly
        // such a case. Whoever checks only for "field missing" builds a preview without images out of
        // it.
        #expect(try Self.trickplay(#"{"Id": "abc", "Trickplay": {}}"#) == nil)
        #expect(try Self.trickplay(#"{"Id": "abc"}"#) == nil)
    }

    @Test("Values without preview images or without an interval yield no preview")
    func rejectsUnusableNumbers() throws {
        // ``Trickplay`` computes an image index from the time — with spacing zero there is none, and
        // the type catches that only by raising the number to a thousandth. Then every preview image
        // would lie on the same sheet. Without images, in turn, the largest valid index would be
        // minus one, and the preview would reach behind the start. Instead of bending such values
        // into shape, it counts as not present.
        let noThumbnails = """
            {"Id": "abc", "Trickplay": {"abc": {"320": {
                "Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10,
                "ThumbnailCount": 0, "Interval": 10000}}}}
            """
        let noInterval = """
            {"Id": "abc", "Trickplay": {"abc": {"320": {
                "Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10,
                "ThumbnailCount": 154, "Interval": 0}}}}
            """

        #expect(try Self.trickplay(noThumbnails) == nil)
        #expect(try Self.trickplay(noInterval) == nil)
    }

    @Test("With several widths the largest is not taken")
    func picksModestWidth() throws {
        // The test server generates only 320. A server that also creates larger sheets must not make
        // the preview more expensive: a sheet with a hundred images of 320 points each weighed a
        // measured 1.4 MB, at 640 it would be four times that — for a preview that appears a few
        // hundred points wide while scrubbing. The sheet would arrive only when the thumb has already
        // moved on.
        let manyWidths = """
            {"Id": "abc", "Trickplay": {"abc": {
                "320": {"Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10,
                        "ThumbnailCount": 154, "Interval": 10000},
                "640": {"Width": 640, "Height": 360, "TileWidth": 10, "TileHeight": 10,
                        "ThumbnailCount": 154, "Interval": 10000},
                "1280": {"Width": 1280, "Height": 720, "TileWidth": 10, "TileHeight": 10,
                         "ThumbnailCount": 154, "Interval": 10000}}}}
            """

        #expect(try Self.trickplay(manyWidths)?.width == 320)
    }

    @Test("If there are only large widths, the smallest of them is taken")
    func fallsBackToSmallestAvailable() throws {
        // A preview that is too large is better than none. Whoever insists on the preferred width here
        // shows nothing while scrubbing — on a server that did generate the sheets.
        let onlyLarge = """
            {"Id": "abc", "Trickplay": {"abc": {
                "640": {"Width": 640, "Height": 360, "TileWidth": 10, "TileHeight": 10,
                        "ThumbnailCount": 154, "Interval": 10000},
                "1280": {"Width": 1280, "Height": 720, "TileWidth": 10, "TileHeight": 10,
                         "ThumbnailCount": 154, "Interval": 10000}}}}
            """

        #expect(try Self.trickplay(onlyLarge)?.width == 640)
    }

    @Test("With several versions the title's own counts")
    func prefersOwnMediaSource() throws {
        // On the outside the server nests by media source identifier. With two versions of a film —
        // theatrical cut and director's cut — there are two entries there, and they have different
        // lengths. The preview of the wrong version shows images from the wrong place while scrubbing,
        // which drifts further apart as time goes on.
        let twoVersions = """
            {"Id": "abc", "Trickplay": {
                "zzz": {"320": {"Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10,
                                "ThumbnailCount": 900, "Interval": 10000}},
                "abc": {"320": {"Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10,
                                "ThumbnailCount": 154, "Interval": 10000}}}}
            """

        let trickplay = try #require(try Self.trickplay(twoVersions))
        #expect(trickplay.thumbnailCount == 154)
        #expect(trickplay.sheetBase.path.contains("/Videos/abc/Trickplay/320"))
    }
}
