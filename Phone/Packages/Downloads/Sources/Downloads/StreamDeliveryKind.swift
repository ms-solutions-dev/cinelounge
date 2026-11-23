import Foundation

/// What **really** lies at the other end of the address — **a table and not a switch.**
///
/// **The occasion is a requirement from 2026-09-09:** cover general formats that may
/// have been forgotten, so that it does not turn up on every single attempt — in short,
/// make it universal. That pointed at the **construction**, not at a bug: a binary switch
/// ("file or HLS") is caught out again by the next host; a named table is not — what it
/// cannot do, it can at least **say**.
///
/// **The product rule is: what plays, downloads.** In essence: technically, a browser on
/// iOS can download anything it can open full-screen and play, no matter what.
/// Every case here therefore carries **either** a strategy **or** a rejection with a
/// reason. What it never carries is "Connection lost" for something that was not a
/// connection problem at all.
///
/// ## Why not by portal name, and why not by status either
///
/// **Not by name**, because the same portal reader delivers both: Serieshub gives a
/// file, flatone a playlist — both over the same bridge, both over `/play`.
///
/// **And not by status either**, and that is the measurement that refuted the first draft
/// of this file. The brief was: *"The bridge answers `/stream` with 200
/// for playlists and with 206 for files — that is how to tell the cases apart."* Measured on
/// 2026-09-09 on the portals bridge (home server, port 8099), flatone · clipsite:
///
/// ```
/// curl -H "Range: bytes=0-1" "…/strom?adresse=…%2Fplaylist.m3u8"
///   → 206 Partial Content
///   → accept-ranges: bytes
///   → content-range: bytes 0-1/53127
///   → content-type: application/vnd.apple.mpegurl
/// ```
///
/// **An HLS playlist with 206 and `accept-ranges: bytes`.** A switch on the status
/// would have taken it for a file and written 53 127 bytes of text to disk —
/// building exactly the error it was built against. The same measurement also shows
/// why the bridge's own report is not enough: `/play` reports `kind: "file"` for the same address.
///
/// **That is why the content decides before the status:** first what it is, then how it
/// is delivered. That is the order in which ``from(_:)`` asks, and it is the
/// only non-interchangeable part of this file.
///
/// ## The cut is the same as in the rest of the package
///
/// ``Resumability/fromResponse(status:acceptsRanges:)`` computes from a response and
/// needs no network. Here the same thing stands one level above: from **one** probe a
/// name. `Resumability` was explicitly **not** extended — it answers
/// a yes/no question about a range request and is used that way in four places; a
/// type with six cases next to it is something different from a `Bool` with six meanings.
public enum DeliveryKind: Sendable, Hashable {

    /// **A file, piece by piece.** `206` with `Accept-Ranges: bytes` — today's route via
    /// ``BackgroundSession`` and ``BlockFetcher``.
    case fileInPieces

    /// **A file, but only in one piece.** `200`, and the range was ignored.
    ///
    /// **That is not a rejection but a worse strategy**, and it was missing entirely until
    /// 2026-09-09. The case is measured and recorded in the roadmap (the "Aloha" addendum of
    /// 2026-09-08) on our own media server: `/Videos/{id}/stream.mp4?VideoBitrate=…` answers
    /// with **200** and `Accept-Ranges: none`. Such a thing can still be downloaded — in one go,
    /// without resuming. **A download that starts over after an interruption is better
    /// than none; it just has to say so.**
    case wholeFile

    /// **An HLS playlist.** What is in it is only told by ``StreamPlaylist``.
    case hls

    /// **MPEG-DASH.** Recognised and named, not built — see ``Rejection/dash``.
    case dash

    /// **A stream without an end.** MPEG-TS without a length: the Xtream case from roadmap E34.
    case endlessStream

    /// **A redirect.** `3xx` with `Location` — the thing lives elsewhere.
    ///
    /// **Measured on 2026-09-09 on this project's provider access:**
    /// `…/movie/<user>/<pass>/344604.mp4` answers with **302** to a **different**
    /// machine (`<provider-host>:8888/live/play/<token>/…`), and only there is the
    /// file — `206`, `video/mp4`, 2.5 GB.
    ///
    /// **That is why this is a case of its own and not `.unclear`.** `URLSession` follows
    /// by itself; a probe that nevertheless stopped at the `302` would report "unknown
    /// format" for an ordinary MP4 file. The delivery type is measured **at the end of the
    /// chain** — this case is the reminder of that and the information for when the
    /// chain breaks off.
    case redirect(URL?)

    /// **The access is busy.** An error status from the provider, because the account allows exactly one
    /// connection.
    ///
    /// **Measured on 2026-09-09:** `player_api.php` reports `max_connections: 1`, and a
    /// second simultaneous request gets **551**. Until 2026-09-09 this would have landed in this
    /// table as "no ranges" — a statement about the **server** where one
    /// about the **moment** belongs. The difference is the next step:
    /// "no ranges" means "take a different version", "busy" means "wait until
    /// nobody is watching any more", and only the second goes away by itself.
    case accessBusy

    /// **Something else.** The content type is included so that the line in the ledger
    /// answers the question instead of posing it.
    case unclear(String?)

    /// Whether this case has a download route at all.
    ///
    /// **A redirect is downloadable and not "maybe".** It is not a destination but
    /// a signpost; whoever follows it ends up at one of the other rows of this table.
    public var isDownloadable: Bool {
        switch self {
        case .fileInPieces, .wholeFile, .hls, .redirect: true
        case .dash, .endlessStream, .accessBusy, .unclear: false
        }
    }

    /// The rejection for a delivery type that has no download route — `nil` where there is one.
    public var rejection: Rejection? {
        switch self {
        case .fileInPieces, .wholeFile, .hls, .redirect: nil
        case .dash: .dash
        case .endlessStream: .endlessStream
        case .accessBusy: .accessBusy
        case .unclear(let kind): .unknownFormat(kind)
        }
    }

    /// **Why it does not work — named and not described.**
    ///
    /// **The purpose is a sentence on the screen that knows the next step.** The same
    /// reasoning as at ``LoadError``: "Connection lost" for a title with
    /// rights management is information that points in the wrong direction — the
    /// viewer waits for a better network, and a better network never helps.
    public enum Rejection: Sendable, Hashable {

        /// **MPEG-DASH.** Not found on the bridge on 2026-09-09 for any of the four portals
        /// (Serieshub, Animehub, ARD, flatone deliver MP4 or HLS). Hence
        /// recognised and named, but not built: a second playlist reader for a case
        /// that no source of this project delivers would be building on suspicion — and the
        /// difference from today is not the missing reader anyway, but the missing
        /// **sentence**.
        case dash

        /// **A stream without an end.** No download, because there is nothing to complete; that
        /// is the same boundary that ``SourceKind`` draws for channel lists.
        case endlessStream

        /// **An HLS playlist without `#EXT-X-ENDLIST`.** It keeps growing; what one would
        /// download today would be a recording and not a copy.
        case liveWithoutEnd

        /// **Rights management** — FairPlay, Widevine, `SAMPLE-AES`. **Is not downloaded,
        /// and that is not a gap but the right answer.**
        case rightsManagement

        /// **Encrypted segments** (`#EXT-X-KEY:METHOD=AES-128`).
        ///
        /// **Rejection and not decryption — decided by measurement.** The key
        /// would be in the playlist and retrievable; CBC via CommonCrypto would need no new
        /// dependency. Checked on the bridge on 2026-09-09, however, **none**
        /// of the three reachable HLS deliveries carries an `#EXT-X-KEY`: ARD (TS, 290 segments),
        /// one provider via flatone (fMP4, 211 segments), another via flatone (TS).
        /// A decryptor without a single case on which it could be verified would be
        /// code nobody has ever seen working. The reason travels along so that the line
        /// in the ledger says which method it was.
        case encrypted(String)

        /// **Something that is none of the cases.** The content type is included — the information
        /// needed for the next unknown host.
        case unknownFormat(String?)

        /// **A playlist without segments.** Happens when a reader passes an error page through as
        /// `m3u8`.
        case emptyList

        /// **The access is busy right now** — and that is the only rejection here that goes
        /// away by itself.
        ///
        /// That is why it stands next to the others and not under them: whoever reported it as
        /// "not resumable" would send the viewer to the download sheet to pick a
        /// different version — and none of them would help, because the limit is tied to the **account**
        /// and not to the version.
        case accessBusy

        /// **The portal finds no video address.** Not the network, not the format —
        /// the reader itself.
        ///
        /// **Measured on 2026-09-09**, all four titles of the level
        /// `flatone › Clips`: `/play` answers with **502**, and the bridge's log
        /// says verbatim
        ///
        ///     flatone.clips:
        ///     error: could not find the video on the page
        ///
        /// The site rebuilt its player, and the reader can no longer reach the address. **Other sources of the same portal
        /// resolve cleanly** — so it is neither
        /// "flatone broken" nor an app error.
        ///
        /// **Why this is a case of its own and not `network`:** Until now the
        /// screen said "Connection lost. Tap Resume once the network is back."
        /// That is wrong three times over — the network was fine, Resume never helped,
        /// and the viewer looked for the fault in themselves. A reader that can no longer read a site
        /// is a message about **the portal**, and it does not go away by
        /// itself: it goes away when someone updates the reader.
        case noAddress(String?)
    }
}

/// The one probe from which the delivery type is derived.
///
/// **A type of its own and not five parameters.** ``BlockResponse`` would be the obvious
/// carrier and is the wrong one: it is the answer to a **range request** and therefore
/// carries `totalLength`, `tag` and `changed` — information that a probe does not
/// need and that an HLS playlist does not have. A type that answers the second with the
/// first is the place where someone later compares the `tag` of a playlist.
public struct Probe: Sendable, Equatable {

    public let status: Int
    /// `Content-Type` of the response.
    public let contentType: String?
    public let acceptsRanges: String?
    /// `Content-Range` — present means: the range was answered.
    public let contentRange: String?
    /// `Content-Length` of the **whole** file, as far as the response states it.
    public let length: Int64?

    /// `Location` — set only for a redirect.
    public let next: URL?

    /// **The first bytes of the body — and they are not an extra.**
    ///
    /// A host that writes `application/octet-stream` over an `m3u8` is no
    /// invention but the normal case with small readers; the seven characters `#EXTM3U`
    /// are then the only truth in the whole response. Conversely, half a
    /// kilobyte costs nothing — the same calculation as for ``Resumability``, where a
    /// `Range: bytes=0-1` decides the whole download job.
    public let start: Data

    public init(
        status: Int, contentType: String? = nil, acceptsRanges: String? = nil,
        contentRange: String? = nil, length: Int64? = nil, next: URL? = nil,
        start: Data = Data()
    ) {
        self.status = status
        self.contentType = contentType
        self.acceptsRanges = acceptsRanges
        self.contentRange = contentRange
        self.length = length
        self.next = next
        self.start = start
    }

    /// How many bytes a probe fetches.
    ///
    /// **512 and not 2.** With two bytes the body holds `#E`, and that is no
    /// different from any text response. With half a kilobyte the
    /// first line of a playlist is fully there — for the measured flatone playlist
    /// even the first two segments.
    public static let bytes: Int64 = 512

    /// The start of the body as text, without leading whitespace and without a byte order mark.
    ///
    /// **The mark is not a theoretical case.** `#EXTM3U` with `EF BB BF` in front comes from
    /// every reader that produced the playlist with Windows tools; a comparison with
    /// `hasPrefix` says no there and would be right — for the wrong result.
    public var text: String {
        var raw = start
        if raw.starts(with: [0xEF, 0xBB, 0xBF]) { raw = raw.dropFirst(3) }
        let text = String(decoding: raw, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension DeliveryKind {

    /// **The switch — in one place, and the order is the reasoning.**
    ///
    /// The questions go from the inside out: first **what** was delivered (content type and the
    /// first bytes), then **how** (status and ranges). The other way round, the
    /// delivery wins over the content — and that is exactly the measured error of 2026-09-09
    /// described above at ``DeliveryKind``: an HLS playlist with `206` and `accept-ranges: bytes`.
    ///
    /// **What explicitly does not appear here: the file extension.** `…/index.m3u8` looks
    /// unambiguous and is not — the address of the ARD master playlist ends in
    /// `master.m3u8?__b__=200`, that of one provider in `.mp4.m3u8`, and the one from clipsite is called
    /// `playlist.m3u8`, while `/play` reports `kind: "file"` for it. Whoever reads the extension
    /// reads a claim; whoever reads the body reads the thing.
    public static func from(_ probe: Probe) -> DeliveryKind {
        let kind = probe.contentType?.lowercased() ?? ""
        let start = probe.text

        // **A redirect is not yet a delivery.** It comes first because its
        // body is empty and its content type `text/html` — both information about the
        // signpost and none about the destination. Measured on the provider access: `302` to a
        // different machine, and only there do the 2.5 GB lie.
        if (300...399).contains(probe.status) { return .redirect(probe.next) }

        // **The busy access comes before all format questions**, because it is not a
        // format question at all. `551` is this provider's measured status for a
        // second simultaneous connection; `429` is the same thing in the language
        // of the standard, and some panels write `509` for it.
        if Self.busyStatuses.contains(probe.status) { return .accessBusy }

        // **HLS first.** `application/vnd.apple.mpegurl` and `application/x-mpegURL` are
        // both measured — the ARD variant comes with the second, the flatone playlist
        // with the first. A comparison on "mpegurl" matches both and also the
        // spellings still to come.
        if kind.contains("mpegurl") || start.hasPrefix("#EXTM3U") { return .hls }

        // **DASH afterwards**, for the same reason: a reader that passes an `.mpd` through as
        // `application/xml` would otherwise become `.unclear` — correct, but without the
        // information the next person searching needs.
        if kind.contains("dash+xml") || start.contains("<MPD") { return .dash }

        // **A transport stream without length and without range has no end.** That is the
        // case from E34: the provider access whose `allowed_output_formats` lists only `ts`
        // answers with `200` and `video/mp2t` — and it never stops. Whoever takes that for a
        // file writes until the disk is full.
        //
        // **With** a length, the same content type is an ordinary file: an HLS segment is
        // `video/mp2t` and very much has an end.
        if kind.contains("mp2t"), probe.length == nil, probe.contentRange == nil {
            return .endlessStream
        }

        // Only here does the delivery count — and for that, what
        // ``Resumability/fromResponse(status:acceptsRanges:)`` says still applies: exactly
        // `206` counts. Whoever answers a range request with `200` has
        // ignored the range; their `Accept-Ranges` is a promise they broke in the same
        // breath.
        //
        // **And `Accept-Ranges` is not believed here either, only read along.**
        // Measured on 2026-09-09 on this project's provider access, it says
        // `Accept-Ranges: 0-2511729429` — the server writes the range where the
        // word `bytes` belongs. The response is nevertheless a perfectly good `206` with a
        // valid `Content-Range`; whoever made the broken header a condition would have rejected a
        // 2.5 GB file that is delivered piece by piece. **What the response
        // proves counts; what it claims appears only in the trace.**
        if Resumability.fromResponse(
            status: probe.status, acceptsRanges: probe.acceptsRanges)
        {
            return .fileInPieces
        }

        // **No `2xx` is no delivery at all.** The content type of an error page is
        // `application/json` or `text/html`, and downloading either as a "file in one piece"
        // would produce a film file made of an error message — measured on the bridge exactly
        // like this: `502` with `{"detail":"der Puffer trägt nicht mehr"}`.
        guard (200...299).contains(probe.status) else { return .unclear(probe.contentType) }

        if kind.hasPrefix("video/") || kind.hasPrefix("audio/")
            || kind.contains("octet-stream") || kind.contains("matroska")
        {
            return .wholeFile
        }

        return .unclear(probe.contentType)
    }

    /// The statuses with which a provider panel expresses "one connection too many".
    ///
    /// **`551` is measured and appears in no standard.** Xtream panels invent their own
    /// numbers in this range — this project already saw `512` on 2026-09-07.
    /// (see ``ConnectionScarcity``) and `551` on 2026-09-09. `429` and `509` are
    /// the same statement in the language of the standard and of the panels, respectively.
    public static let busyStatuses: Set<Int> = [429, 509, 512, 551]
}
