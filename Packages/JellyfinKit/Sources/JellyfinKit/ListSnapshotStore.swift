import Core
import CryptoKit
import Foundation

/// Stores list responses as JSON snapshots in the caches directory.
///
/// **The step from session memory to startup memory.** The source's cache lives in
/// memory and dies with the app — every cold start therefore reloaded everything, and
/// on this connection that means seconds in front of an empty screen, the first time
/// every view is opened. With the snapshot the view shows the last state immediately,
/// and the server is asked in the background; anything new then slides in quietly.
///
/// **A snapshot is a convenience, not the truth.** That is why every error — full
/// disk, unreadable format after an app update — is silently skipped instead of
/// reported: the next server fetch simply answers the question, with a wait. And that
/// is why everything lives in the caches directory, which the system may empty at any
/// time.
///
/// Snapshots are stored **separately per server and user**: whoever signs out and signs
/// in again with a different account must not see the previous account's lists — not
/// even for the moment until the first server response.
///
/// Only what signing out needs is public: access via the account data, and
/// ``removeAll()``. Reading and writing stay the source's business — writing past the
/// snapshots from outside would mean maintaining two truths.
public struct ListSnapshotStore: Sendable {

    /// Where this access's snapshots live.
    let directory: URL

    /// Anything older is not served at all: someone who has not opened the app for a month
    /// no longer has a "last state" but an archive — and a visibly outdated catalog is worse
    /// than a wait.
    static let maxAge: TimeInterval = 30 * 24 * 3600

    public init(serverURL: URL, userID: String) {
        let base =
            FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        // The folder name is derived from server and user, but hashed: a server address
        // contains host and port, and those do not belong in plain text in directory
        // listings.
        let identity = Self.digest("\(serverURL.absoluteString)|\(userID)")
        self.directory = base.appending(path: "CineLounge/Lists/\(identity)")
    }

    /// For the checks: any (throwaway) directory.
    init(directory: URL) {
        self.directory = directory
    }

    /// Timestamp and payload together in one file — the stamp decides whether the content
    /// still counts as the "last state" at all.
    private struct Envelope<Value: Codable>: Codable {
        let savedAt: Date
        let value: Value
    }

    /// Reads a snapshot, or nothing.
    ///
    /// `nil` covers every case — never written, too old, unreadable after a format change.
    /// For the caller they are the same: there is no last state, so the server decides.
    func load<Value: Codable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = try? Data(contentsOf: fileURL(for: key)),
            let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: data),
            Date.now.timeIntervalSince(envelope.savedAt) < Self.maxAge
        else { return nil }
        return envelope.value
    }

    /// Writes immediately and swallows errors — the synchronous core.
    ///
    /// Separate from ``save(_:key:)`` so the checks do not have to wait for a detached task
    /// to see the result.
    func write<Value: Codable>(_ value: Value, key: String) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Envelope(savedAt: .now, value: value))
            try data.write(to: fileURL(for: key), options: .atomic)
        } catch {
            // bewusst still: see the type comment. A failed snapshot costs a wait at the next
            // start — a message about it would now cost attention for nothing.
        }
    }

    /// Writes away from the caller.
    ///
    /// The source is an actor, and encoding plus disk access on it would mean: every other
    /// request waits until a library with a thousand titles is on disk as JSON.
    func save<Value: Codable & Sendable>(_ value: Value, key: String) {
        Task.detached(priority: .utility) {
            self.write(value, key: key)
        }
    }

    func remove(key: String) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    /// Clears all snapshots of this access — the handle for signing out.
    ///
    /// Whoever rebuilds the same holder from the same account data ends up in the same
    /// folder; the sign-out path in the app relies on that.
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The file name for the key.
    ///
    /// Hashed, not sanitized: a key contains colons and arbitrary search terms — any
    /// replacement rule would invite two keys that land on the same file.
    func fileURL(for key: String) -> URL {
        directory.appending(path: Self.digest(key) + ".json")
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
