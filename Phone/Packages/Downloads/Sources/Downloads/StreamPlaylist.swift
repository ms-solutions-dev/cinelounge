import Foundation

/// An HLS playlist, read — **pure computation, no network.**
///
/// **This is the same cut as everywhere in this package**, and for the same reason: what
/// is difficult about a playlist is decisions — which tier, where does it end, is
/// it encrypted, does an initialisation belong in front. None of them needs a line,
/// and all of them are wrong if they only show up on the plane. ``Resumability`` stands
/// next to ``BackgroundSession`` and not inside it for the same reason.
///
/// **Measured on 2026-09-09 on the portals bridge (home server, port 8099), and the three measurements are recorded as
/// test material in `StreamPlaylistTests`:**
///
/// | Source | Form | Segments | Peculiarity |
/// |---|---|---|---|
/// | ARD (BR) | master playlist → tier playlist | 290 · TS | `#EXT-X-I-FRAME-STREAM-INF` alongside |
/// | one provider via flatone | master playlist → tier playlist | 211 · fMP4 | `#EXT-X-MAP` |
/// | clipsite via flatone | **directly** a tier playlist | TS | no master playlist |
///
/// **The third row is the reason ``read(_:from:)`` can return both and
/// is not two functions.** Whoever expects a master playlist and gets a tier playlist
/// has done nothing wrong — the playlist itself says so, namely through its markers. Two
/// separate readers would mean the caller knows beforehand what is coming; it never does.
public enum StreamPlaylist {

    // MARK: - What is in it

    /// A resolution tier from the master playlist (`#EXT-X-STREAM-INF`).
    public struct Tier: Sendable, Hashable {
        public let address: URL
        /// `BANDWIDTH` in bit/s — the peak rate, not the average.
        public let bandwidth: Int?
        public let width: Int?
        public let height: Int?
        /// `NAME`, where the playlist has one. ARD has none, and neither does the second provider.
        public let name: String?
        public let codecs: String?

        public init(
            address: URL, bandwidth: Int? = nil, width: Int? = nil, height: Int? = nil,
            name: String? = nil, codecs: String? = nil
        ) {
            self.address = address
            self.bandwidth = bandwidth
            self.height = height
            self.width = width
            self.name = name
            self.codecs = codecs
        }
    }

    /// A piece of video — **with a range, when several lie in one file.**
    public struct Segment: Sendable, Hashable {
        public let address: URL
        public let duration: TimeInterval
        /// `#EXT-X-BYTERANGE` — then several segments lie in **one** file, and a range of it
        /// is fetched. `nil` means: the whole file.
        public let area: ClosedRange<Int64>?

        public init(address: URL, duration: TimeInterval = 0, area: ClosedRange<Int64>? = nil) {
            self.address = address
            self.duration = duration
            self.area = area
        }
    }

    /// What kind of container the segments are — **and that decides what has to end up on
    /// disk.**
    ///
    /// MPEG-TS segments concatenated give a file with the same form as
    /// any transport stream. fMP4 segments give **nothing** without their initialisation —
    /// it holds the track descriptions, and a player that does not see them has
    /// bytes without meaning. That is why this is a value of its own and not a side note.
    public enum Container: Sendable, Hashable {
        /// MPEG-TS. ARD and clipsite deliver this.
        case transportStream
        /// Fragmented MP4, recognised by `#EXT-X-MAP`. One flatone provider delivers this.
        case fragmentedMP4
    }

    /// A tier playlist — the playlist with the segments.
    public struct VariantList: Sendable, Hashable {
        public let segments: [Segment]

        /// The initialisation from `#EXT-X-MAP` — **the first piece of the finished file.**
        ///
        /// **It is a ``Segment`` and not a `URL`**, because it may carry a `BYTERANGE`:
        /// with a reader that packs everything into one file, the first
        /// thousand bytes are the initialisation and the rest are the segments.
        public let initialization: Segment?

        /// `#EXT-X-ENDLIST` seen. **Without it this is not a download** — see
        /// ``DeliveryKind/Rejection/liveWithoutEnd``.
        public let isComplete: Bool

        /// The method from `#EXT-X-KEY`, if one is set and is not `NONE`.
        public let encryption: String?

        /// Whether the method is rights management (FairPlay, Widevine, `SAMPLE-AES`).
        public let rightsManagement: Bool

        public var container: Container {
            initialization == nil ? .transportStream : .fragmentedMP4
        }

        /// How long the title plays — the sum of the `#EXTINF`.
        ///
        /// **The only size information a playlist gives beforehand.** Nobody knows bytes
        /// before the last segment is on disk; seconds are in every line. For
        /// ``DownloadJob/runtime`` this is the number the portals otherwise lack —
        /// measured, `/p/serieshub/list` returns `dauer_minuten: null` there throughout.
        public var duration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }
    }

    /// What a playlist is — **the playlist says so and not the caller.**
    public enum Content: Sendable, Hashable {
        case main([Tier])
        case tier(VariantList)
    }

    // MARK: - Reading

    /// Reads a playlist. Relative addresses are resolved against `basis`.
    ///
    /// **`basis` is the address of the playlist itself and not that of the title.** For a
    /// master playlist whose tiers are relative (`720p/video.m3u8`) and whose tier playlist
    /// again lists its segments relatively (`seg-1.ts`), these are **two different**
    /// bases — the second is the resolved address of the first. Whoever resolved both against the
    /// title address would get addresses at the second step that point one level too high;
    /// that is the classic error at this spot and it only shows up at the
    /// second segment.
    ///
    /// - Throws: ``LoadError/notLoadable(_:)`` if the text is not a playlist or carries no
    ///   entries. **And here and not at the caller:** a playlist without
    ///   segments is, as measured on the bridge, the normal case for an error page passed
    ///   through, and "zero segments downloaded" would show as a finished download on the screen.
    public static func read(_ text: String, from basis: URL) throws -> Content {
        let rows = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let first = rows.first, first.hasPrefix("#EXTM3U") else {
            throw LoadError.notLoadable(.unknownFormat(nil))
        }

        // **The decision is made on `#EXT-X-STREAM-INF` and nothing else.** A
        // master playlist has no `#EXTINF`, a tier playlist no `#EXT-X-STREAM-INF`; a
        // playlist with both does not exist in the standard. The check is for the master playlist
        // because its marker is the rarer one — clipsite, as measured, delivers none at all.
        if rows.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            return .main(try mainList(rows, from: basis))
        }
        return .tier(try variantList(rows, from: basis))
    }

    private static func mainList(_ rows: [String], from basis: URL) throws -> [Tier] {
        var slots: [Tier] = []
        var pending: [String: String]?

        for row in rows {
            if row.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(hinter(row))
                continue
            }
            // **`#EXT-X-I-FRAME-STREAM-INF` is not a tier, and that is no detail.**
            // The ARD master playlist lists five of them, right after the five real ones. They
            // contain only keyframes — meant for scrubbing in the preview. Whoever
            // counted them would offer ten tiers, and half of them would produce a film of
            // still frames. They carry their address in a `URI` attribute and **not** in
            // the following line; without this branch they would fall through anyway, but silently — and
            // silent is the wrong thing here.
            if row.hasPrefix("#EXT-X-I-FRAME-STREAM-INF") { continue }
            if row.hasPrefix("#") { continue }

            guard let attributes = pending else { continue }
            pending = nil
            guard let address = address(row, from: basis) else { continue }

            let (width, height) = resolution(attributes["RESOLUTION"])
            slots.append(
                Tier(
                    address: address,
                    bandwidth: attributes["BANDWIDTH"].flatMap { Int($0) },
                    width: width, height: height,
                    name: attributes["NAME"], codecs: attributes["CODECS"]))
        }

        guard !slots.isEmpty else { throw LoadError.notLoadable(.emptyList) }
        return slots
    }

    private static func variantList(_ rows: [String], from basis: URL) throws -> VariantList {
        var segments: [Segment] = []
        var initialization: Segment?
        var isComplete = false
        var method: String?
        var permissions = false

        var duration: TimeInterval = 0
        var area: ClosedRange<Int64>?
        /// Where the previous segment ended — for a `#EXT-X-BYTERANGE` without `@`.
        var running: [URL: Int64] = [:]

        for row in rows {
            if row.hasPrefix("#EXTINF:") {
                let value = hinter(row).split(separator: ",", maxSplits: 1)[0]
                duration = Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
                continue
            }
            if row.hasPrefix("#EXT-X-BYTERANGE:") {
                area = byteRange(hinter(row), from: nil)
                continue
            }
            if row.hasPrefix("#EXT-X-MAP:") {
                let attributes = self.attributes(hinter(row))
                if let raw = attributes["URI"], let address = address(raw, from: basis) {
                    initialization = Segment(
                        address: address, duration: 0,
                        area: attributes["BYTERANGE"].flatMap { byteRange($0, from: nil) })
                }
                continue
            }
            if row.hasPrefix("#EXT-X-KEY:") || row.hasPrefix("#EXT-X-SESSION-KEY:") {
                let attributes = self.attributes(hinter(row))
                let methodName = attributes["METHOD"] ?? "NONE"
                if methodName != "NONE" {
                    method = methodName
                    permissions = isRightsManagement(
                        method: methodName, format: attributes["KEYFORMAT"])
                }
                continue
            }
            if row.hasPrefix("#EXT-X-ENDLIST") {
                isComplete = true
                continue
            }
            if row.hasPrefix("#") { continue }

            guard let address = address(row, from: basis) else { continue }

            // **A `#EXT-X-BYTERANGE` without `@` continues from the previous piece of the same
            // file.** That is what the standard says and it is the usual notation: only
            // the first segment names its start, all further ones continue counting. Whoever read the
            // missing start as zero would fetch the same beginning of the
            // file for every segment — a film file made of the same second, a hundred times.
            var isFinal = area
            if let raw = area, raw.lowerBound < 0 {
                let start = running[address] ?? 0
                isFinal = start...(start - raw.lowerBound - 1)
            }
            if let isFinal { running[address] = isFinal.upperBound + 1 }

            segments.append(Segment(address: address, duration: duration, area: isFinal))
            duration = 0
            area = nil
        }

        guard !segments.isEmpty else { throw LoadError.notLoadable(.emptyList) }
        return VariantList(
            segments: segments, initialization: initialization,
            isComplete: isComplete, encryption: method,
            rightsManagement: permissions)
    }

    // MARK: - Small parts

    /// Alles hinter dem ersten Doppelpunkt.
    private static func hinter(_ row: String) -> String {
        guard let point = row.firstIndex(of: ":") else { return "" }
        return String(row[row.index(after: point)...])
    }

    /// `BANDWIDTH=891872,CODECS="avc1.4d401e,mp4a.40.2",NAME="720p"` into a dictionary.
    ///
    /// **Split by hand and not at commas.** That is exactly where every first draft fails:
    /// `CODECS` regularly contains a comma **itself**, and the ARD master playlist of
    /// 2026-09-09 does so in each of its five lines (`CODECS="avc1.640020,mp4a.40.2"`). A
    /// `split(separator: ",")` yields an attribute named `mp4a.40.2"` there — and the
    /// next real attribute behind it is lost.
    static func attributes(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        var name = ""
        var value = ""
        var inValue = false
        var inQuotes = false

        func create() {
            let n = name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return }
            values[n] = value.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            name = ""
            value = ""
        }

        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                value.append(character)
                continue
            }
            if character == "=", !inValue, !inQuotes {
                inValue = true
                continue
            }
            if character == ",", !inQuotes {
                create()
                inValue = false
                continue
            }
            if inValue { value.append(character) } else { name.append(character) }
        }
        create()
        return values
    }

    /// `1280x720` in zwei Zahlen.
    private static func resolution(_ text: String?) -> (Int?, Int?) {
        guard let split = text?.split(separator: "x"), split.count == 2 else { return (nil, nil) }
        return (Int(split[0]), Int(split[1]))
    }

    /// `<length>[@<start>]`.
    ///
    /// **Without `@` a negative start comes out, and that is intentional.** It is the
    /// message "continues from the previous one", and only the caller knows from what.
    /// A `nil` at this spot would mean "no range", and that is the opposite.
    private static func byteRange(_ text: String, from: Int64?) -> ClosedRange<Int64>? {
        let split = text.trimmingCharacters(in: .whitespaces).split(separator: "@")
        guard let length = Int64(split[0]), length > 0 else { return nil }
        guard split.count == 2, let start = Int64(split[1]) else {
            return (-length)...(-length)
        }
        return start...(start + length - 1)
    }

    /// Whether this method is rights management.
    ///
    /// **`AES-128` with `identity` is ordinary encryption** — a key that
    /// the playlist itself names. Everything else (`SAMPLE-AES`, `SAMPLE-AES-CTR`, a
    /// `KEYFORMAT` such as `com.apple.streamingkeydelivery` for FairPlay or the Widevine UUID)
    /// is a rights system with a server behind it. The difference is no subtlety:
    /// in the first case we lack a decryptor, in the second we lack the **right**.
    private static func isRightsManagement(method: String, format: String?) -> Bool {
        if method != "AES-128" { return true }
        guard let format, !format.isEmpty else { return false }
        return format.lowercased() != "identity"
    }

    /// An address from a line — relative or absolute.
    private static func address(_ raw: String, from basis: URL) -> URL? {
        let clean = raw.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        // **`URL(string:relativeTo:)` and not `appendingPathComponent`.** A relative
        // address may begin with `/` (then only the host counts), with `../` (then it goes
        // up one level) or carry a query. Appending can do none of that and
        // would produce, for `/720p/video.m3u8`, a path that still contains half the old one.
        return URL(string: clean, relativeTo: basis)?.absoluteURL
    }
}
