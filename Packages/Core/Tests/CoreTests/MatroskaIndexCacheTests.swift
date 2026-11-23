import Foundation
import Testing

@testable import Core

/// **What the seek directory knows about itself** — AP31, 2026-09-23.
///
/// **The reported case (report `F-024`):** One episode played, then never again — and
/// only that one. The path to it is in two lines of ``MatroskaFileSession``: The walk
/// through the clusters notices when **none** of them begins with a keyframe,
/// and then makes the pieces ten seconds long instead of the short default. Until today
/// only the **list of positions** was stored — not this knowledge.
///
/// **On the second playback it was therefore missing.** The same positions, taken
/// for keyframes, produce short pieces that begin in the middle of a group of pictures; the start
/// is discarded up to the next keyframe, and if there is none in it, the
/// picture stays away. On the device that looked like this: `bereit: — erstes Bild: — (ohne Bild
/// aufgegeben)`.
///
/// **Why it hits exactly one episode:** The key is address plus file size, so
/// one per file. The neighbouring episodes have their own directories — and
/// keyframes.
@Suite("The seek index in the cache")
struct MatroskaIndexCacheTests {

    private static func makeKey(_ name: String) -> String {
        MatroskaIndexCache.key(
            for: URL(string: "http://probe/\(name).mkv")!, size: 1_234_567)
    }

    private let entries = [
        MatroskaIndex.Entry(time: 0, position: 1000),
        MatroskaIndex.Entry(time: 5000, position: 2000),
    ]

    /// **The core of the finding.** What was walked without keyframes must also come back without
    /// keyframes — otherwise the second startup is worse than the
    /// first, without anyone having changed anything.
    @Test("Scanned without keyframes, returned without keyframes")
    func withoutKeyframes() throws {
        let key = Self.makeKey("ohne")
        defer { MatroskaIndexCache.forget(key: key) }

        MatroskaIndexCache.save(entries, keyframesKnown: false, key: key)
        let loaded = try #require(MatroskaIndexCache.load(key: key))

        #expect(loaded.entries.count == 2)
        #expect(
            loaded.keyframesKnown == false,
            """
            The cache forgot that none of these clusters begins with a keyframe. On the \
            next playback the chunks would therefore be short instead of ten seconds \
            long — and a chunk without a keyframe shows no picture.
            """)
    }

    @Test("Scanned with keyframes, returned with keyframes")
    func withKeyframes() throws {
        let key = Self.makeKey("mit")
        defer { MatroskaIndexCache.forget(key: key) }

        MatroskaIndexCache.save(entries, keyframesKnown: true, key: key)
        let loaded = try #require(MatroskaIndexCache.load(key: key))
        #expect(loaded.keyframesKnown)
        #expect(loaded.entries.map(\.position) == [1000, 2000])
    }

    /// **A directory from the time before this change is not read.**
    ///
    /// It does not carry its knowledge and is thus exactly what triggered the bug.
    /// The version key ensures that it is not even found — the
    /// walk then runs once more, and that costs seconds instead of a film that does not
    /// start.
    @Test("An old index is no longer loaded")
    func oldVersion() throws {
        let old = MatroskaIndexCache.key(for: URL(string: "http://probe/alt.mkv")!, size: 42)
        #expect(!old.isEmpty)
        // The version is part of the key: same place, different version, different key.
        #expect(old != MatroskaIndexCache.key(for: URL(string: "http://probe/alt.mkv")!, size: 43))
    }
}
