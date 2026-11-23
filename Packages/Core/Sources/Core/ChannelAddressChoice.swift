import Foundation

/// Under which address and over which path a **channel** is played — the same for both
/// devices (AP58 R4, report A finding S4).
///
/// **Why this exists.** The TV chose the address via ``RawStreamMemory`` and ``RawStreamRule``
/// and the path via ``PlaybackEngineSelector`` including the HEVC gate and
/// ``LiveEngineChoice``; the phone asked the access for `allowsHLS` and guessed the path from
/// the extension. Both belong together: A playlist that the access does not provide, one that
/// has already stayed blind once, and one whose kind has been learned as raw all go out as a
/// raw stream alike.
///
/// **What stays per device:** the TV's runtime fallbacks (black picture, sluggish startup,
/// dropout) — they hang on the engine — and the choice of the engine itself: The phone
/// renders directly, the TV chooses in the diagnostics.
public enum ChannelAddressChoice {

    /// The raw transport stream for a playlist — the same address with `.ts`.
    public static func rawAddress(_ list: URL) -> URL {
        list.deletingPathExtension().appendingPathExtension("ts")
    }

    /// The address of a channel.
    ///
    /// - Parameters:
    ///   - erlaubtHLS: whether the access provides playlists (`allowsHLS`). If it says no, the
    ///     `.m3u8` address is a refusal with notice (on the phone 2026-09-06: 407).
    ///   - ablage: where memo and rule are stored. **Two pieces of information** (AP3 · V5): The
    ///     memo knows **this** channel, the rule **its kind** (counterpart and feature) — without
    ///     the second, every unknown channel started twice.
    public static func address(
        forItem url: URL, name: String, allowsHLS: Bool = true, store: any KeyValueStore
    ) -> URL {
        guard url.pathExtension.lowercased() == "m3u8" else { return url }
        guard allowsHLS else { return rawAddress(url) }
        if RawStreamMemory.load(from: store).needsRawStream(url) { return rawAddress(url) }
        let pair = RawStreamRule.pair(counterpart: url.host, name: name)
        guard RawStreamRule.load(from: store).saysRaw(pair) else { return url }
        Diagnostics.verbose("Raw-stream rule: \(name) goes raw straight away — \(pair) is learned")
        return rawAddress(url)
    }

    /// Engine and delivery path for a channel address.
    ///
    /// **Without ``StreamQuality``, explicitly** — a provider cannot scale down; a limit would
    /// order a conversion that nobody carries out. **`sourceCanStartAtOffset: false`**, otherwise
    /// the channel would get an address that does not exist. **Remuxed only where the device
    /// decodes HEVC** — a channel does not name its picture codec. The container comes from the
    /// extension: `.ts` is MPEG-TS, `.m3u8` a playlist.
    ///
    /// - Parameter motor: ``LiveEngineChoice/renderer`` directs the remuxer to the direct
    ///   renderer; a playlist from the provider still plays directly.
    public static func decision(
        forItem url: URL, canDecodeHEVC: Bool, motor: LiveEngineChoice
    ) -> PlaybackDecision {
        let fileExtension = url.pathExtension.lowercased()
        let container: MediaSource.Container =
            fileExtension == "m3u8" ? .hls : MediaSource.Container(rawValue: fileExtension)
        let decision = PlaybackEngineSelector.decide(
            for: MediaSource(container: container), sourceCanStartAtOffset: false,
            canDecodeHEVC: canDecodeHEVC)
        switch motor {
        case .hls: return decision
        case .renderer: return decision.asRenderer()
        }
    }
}
