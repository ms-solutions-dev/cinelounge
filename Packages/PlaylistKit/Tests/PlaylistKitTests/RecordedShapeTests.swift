import Foundation
import Testing

@testable import PlaylistKit

/// Where the captures of the real provider lie in the private source.
///
/// `intern/` never reaches the public export, so there these tests are skipped
/// and the synthetic fixtures carry the suite alone.
private enum Recording {

    /// The repository root, found from this file: `Packages/PlaylistKit/Tests/PlaylistKitTests/`.
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("intern/aufnahmen/iptv")

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("get_live_streams.json").path)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: folder.appendingPathComponent(name))
    }
}

/// The synthetic fixtures against the captures they replace.
///
/// **Why these tests are optional.** The fixtures under `Fixtures/` are written by
/// `intern/fixtures-synth/iptv.py`; the captures of the real provider they imitate
/// stay in the private source. Only there can it be checked that the imitation
/// still has the provider's shape — every key, and every type a key takes, the
/// mixed ones included. Without that check the generator could drift into a tidy
/// version of the format, and the parser tests would turn into tests of the tidy
/// version. Outside the private source there is nothing to compare against, and
/// a skip says that more honestly than a pass.
@Suite("Synthetic fixtures keep the provider's shape", .enabled(if: Recording.isAvailable))
struct RecordedShapeTests {

    /// Every JSON file the generator writes.
    static let files = [
        "user_info.json",
        "get_live_categories.json",
        "get_live_streams.json",
        "get_vod_categories.json",
        "get_vod_streams.json",
        "vod_info.json",
        "get_series_categories.json",
        "get_series.json",
        "series_info.json",
        "series_info_ohne_folgen.json",
        "series_info_nur_staffeln.json",
        "short_epg.json",
    ]

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil),
            "Fixture \(name) is missing from the test bundle")
        return try Data(contentsOf: url)
    }

    /// Key path → the JSON types found there. Numeric dictionary keys (season numbers)
    /// collapse to one path, list elements to `[]`.
    private func shape(of data: Data) throws -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        func walk(_ value: Any, _ path: String) {
            switch value {
            case let object as [String: Any]:
                out[path, default: []].insert("object")
                for (key, inner) in object {
                    let step = key.allSatisfy(\.isNumber) ? "<n>" : key
                    walk(inner, path + "." + step)
                }
            case let list as [Any]:
                out[path, default: []].insert("array")
                for inner in list { walk(inner, path + "[]") }
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    out[path, default: []].insert("bool")
                } else if CFNumberIsFloatType(number) {
                    out[path, default: []].insert("float")
                } else {
                    out[path, default: []].insert("int")
                }
            case is String:
                out[path, default: []].insert("string")
            case is NSNull:
                out[path, default: []].insert("null")
            default:
                out[path, default: []].insert("other")
            }
        }
        walk(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]), "")
        return out
    }

    @Test("Every key and every type of the capture is in the fixture", arguments: files)
    func sameShape(file: String) throws {
        let recorded = try shape(of: try Recording.data(file))
        let synthetic = try shape(of: try fixture(file))

        for path in Set(recorded.keys).union(synthetic.keys).sorted() {
            #expect(recorded[path] == synthetic[path], "\(file) at \(path)")
        }
    }

    @Test("The capture passes the same data layer as the fixture")
    func captureStillParses() throws {
        let streams = try XtreamPayload.decoder.decode(
            [XtreamPayload.LiveStream].self, from: try Recording.data("get_live_streams.json"))
        let synthetic = try XtreamPayload.decoder.decode(
            [XtreamPayload.LiveStream].self, from: try fixture("get_live_streams.json"))
        #expect(streams.count == synthetic.count)
        #expect(
            XtreamPayload.sectionTitles(in: streams).count
                == XtreamPayload.sectionTitles(in: synthetic).count)

        let movies = try XtreamVOD.movies(from: try Recording.data("get_vod_streams.json"))
        let fixtureMovies = try XtreamVOD.movies(from: try fixture("get_vod_streams.json"))
        #expect(movies.count == fixtureMovies.count)
        #expect(
            movies.map { $0.source?.container } == fixtureMovies.map { $0.source?.container })

        let episodes = try XtreamVOD.episodes(
            from: try Recording.data("series_info.json"), seriesID: "1", playlistID: "liste1")
        let fixtureEpisodes = try XtreamVOD.episodes(
            from: try fixture("series_info.json"), seriesID: "1", playlistID: "liste1")
        #expect(episodes.count == fixtureEpisodes.count)
        #expect(episodes.first?.source?.bitrate == fixtureEpisodes.first?.source?.bitrate)
    }
}
