import Foundation

/// Writes the blocks one after another into the partial file — **and the file is the state.**
///
/// **No second ledger for progress.** How far a download job has got is in
/// the size of its partial file and nowhere else. A counter next to it would be a second
/// truth that would have to be reconciled with the first after every crash, every memory pressure and every restart
/// — and the one time nobody does, the next
/// block is written at the wrong place.
///
/// **Renamed only when finished.** While downloading it is called `.part`; an
/// aborted file under the final name would look playable and stop in the middle of the
/// film. One notices that on the plane.
public struct PartialWriter: Sendable {

    public let part: URL
    public let done: URL

    public init(folder: URL, identifier: DownloadJob.Identifier) {
        self.part = folder.appendingPathComponent(Store.partialName(forItem: identifier))
        self.done = folder.appendingPathComponent(Store.fileName(forItem: identifier))
    }

    /// How far it has got. **Read from the file, not remembered.**
    ///
    /// **Via `FileManager` and explicitly not via `URL.resourceValues`.** That was a
    /// real bug on 2026-09-08, and it did not look like one: `URL` **caches** its
    /// values per instance. This instance is a stored `let`, so every
    /// further call returned the same number as the first — zero. The state thus never grew, the
    /// loop considered the file unfinished, and it wrote **ninety gigabytes** into the
    /// temp folder until the disk was full.
    ///
    /// `FileManager.attributesOfItem` asks the file system every time. That is not
    /// the slower choice here but the only right one: the value changes after every
    /// block, and that is exactly why it is read.
    public func reached() -> Int64 {
        let values = try? FileManager.default.attributesOfItem(atPath: part.path)
        return (values?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Appends a block, **if the file stands exactly where it begins** — otherwise
    /// nothing, and the answer is `false` (shell check H5, 2026-09-27).
    ///
    /// **The one latch for all write paths.** Two places write into the same
    /// partial file: the running ``BackgroundSession`` and the straggler the system delivers after
    /// a restart (`URLBlockFetcher`). Only the straggler checked the state; if it arrived
    /// while the new session was fetching the same block, the block was in the
    /// file twice and everything behind it shifted by one block length. Checking and appending
    /// therefore happen under one lock — nobody can write in between.
    public func append(_ data: Data, from start: Int64) throws -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard reached() == start else { return false }
        try append(data)
        return true
    }

    private static let lock = NSLock()

    /// Appends a block — **without a latch; writing goes via ``append(_:from:)``.**
    ///
    /// **Appended and not written at a position.** The blocks arrive in the
    /// order in which they were requested; writing at a position would be an
    /// invitation to fetch them concurrently later — and then the correctness of the
    /// file would depend on an order nobody sees any more.
    func append(_ data: Data) throws {
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let mutate = try FileHandle(forWritingTo: part)
        defer { try? mutate.close() }
        try mutate.seekToEnd()
        try mutate.write(contentsOf: data)
    }

    /// The partial file becomes the finished one.
    public func complete() throws {
        if FileManager.default.fileExists(atPath: done.path) {
            try FileManager.default.removeItem(at: done)
        }
        try FileManager.default.moveItem(at: part, to: done)
    }

    /// Discards the partial state — after "different file" or when the user cancels.
    public func discard() throws {
        guard FileManager.default.fileExists(atPath: part.path) else { return }
        try FileManager.default.removeItem(at: part)
    }

    public var isFinished: Bool { FileManager.default.fileExists(atPath: done.path) }
}
