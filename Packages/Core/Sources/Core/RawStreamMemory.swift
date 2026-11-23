import Foundation

/// Which live channels do not tolerate the playlist.
///
/// **Why this memory exists:** an Xtream provider delivers every
/// channel under two extensions — `.m3u8` as a playlist and `.ts` as a raw
/// stream. The playlist is the better route (system player, system bar,
/// no second engine), but it does not hold everywhere: if HEVC is in an
/// MPEG-TS, Apple's player accepts it, plays the **sound** and leaves the picture
/// black — without an error message (viewer finding 2026-08-08, on the device as in the
/// simulator; proven with the 4K channels of the tested provider).
///
/// The app notices this itself and switches. Without this memory it would cost
/// a few seconds of black **every time** — when zapping, that is on every visit
/// to the same channel again. Here is what was noticed once; the
/// next time the route goes straight via the raw stream.
///
/// What is remembered is the **URL without the extension**: it survives a restart, and the
/// provider assigns its channel numbers stably.
public struct RawStreamMemory: Sendable {

    static let key = "live.rawStreams"

    /// How many channels are remembered at most.
    ///
    /// A limit, because the list would otherwise grow with every new provider and
    /// never shrink. Two hundred are more than a viewer ever zaps through,
    /// and stay tiny as a row in the Keychain.
    static let limit = 200

    private var addresses: [String]

    public init(addresses: [String] = []) {
        self.addresses = addresses
    }

    /// The URL without the extension — the key of this memory.
    static func key(for url: URL) -> String {
        url.deletingPathExtension().absoluteString
    }

    /// How many channels are remembered — for the trace.
    public var count: Int { addresses.count }

    public func needsRawStream(_ url: URL) -> Bool {
        addresses.contains(Self.key(for: url))
    }

    /// Remembers a channel. The newest goes first, so that the limit hits the
    /// oldest and not the one that was just noticed.
    public mutating func remember(_ url: URL) {
        let entry = Self.key(for: url)
        addresses.removeAll { $0 == entry }
        addresses.insert(entry, at: 0)
        if addresses.count > Self.limit {
            addresses.removeLast(addresses.count - Self.limit)
        }
    }

    /// Forgets a channel — the memory can heal.
    ///
    /// **Without this route an entry is a verdict for life**
    /// (device finding 2026-08-15, Telve 1 HEVC): the channel was on the
    /// list once, from then on always went via the raw stream — and when the
    /// provider let exactly this route die ("0 s of 0 s", twice), the
    /// channel was permanently dead, although the playlist via the remuxer
    /// would long since have worked again. Whoever sees the raw stream fail
    /// deletes the entry; the next visit tries the better
    /// route again and remembers the result anew.
    public mutating func forget(_ url: URL) {
        let entry = Self.key(for: url)
        addresses.removeAll { $0 == entry }
    }

    // MARK: - Ablage

    public static func load(from store: any KeyValueStore) -> RawStreamMemory {
        // Line-separated like the other lists of this app: in a URL
        // everything occurs except the line break.
        let raw = (try? store.value(for: key)) ?? ""
        return RawStreamMemory(addresses: raw.split(separator: "\n").map(String.init))
    }

    public func save(to store: any KeyValueStore) {
        if addresses.isEmpty {
            try? store.remove(Self.key)
        } else {
            try? store.set(addresses.joined(separator: "\n"), for: Self.key)
        }
    }
}
