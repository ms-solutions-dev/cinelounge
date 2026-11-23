import Foundation

/// An entry in the storage budget: name, size, and whether it stays.
///
/// **The third attribute is the one that matters.** The TV shows a listing that says for
/// each entry "will be cleaned up" or "stays" — this honesty is
/// adopted and **corrected** in the process: a deleted film does not come back the next
/// time the app opens, a deleted poster does. Calling both "storage" and making them
/// look alike is the reason viewers delete their downloads by accident.
public struct LineItem: Sendable, Hashable, Identifiable {

    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case downloads = "vorrat"
        case frames = "bilder"
        case channelsAndGuide = "senderUndProgramm"
        case episodeIndex = "folgenverzeichnis"
        case libraryLists = "listenDerMediathek"
        case diagnosticTraces = "diagnosespuren"
        case other = "uebriges"
    }

    public var id: Kind { kind }
    public let kind: Kind
    public var bytes: Int64

    public init(kind: Kind, bytes: Int64) {
        self.kind = kind
        self.bytes = bytes
    }

    /// **Whether it stays until someone deletes it.**
    ///
    /// Only the downloads. Everything else is cache and comes back — that is not a
    /// judgement but the information that is missing before cleaning up.
    public var remains: Bool { kind == .downloads }

    public var key: String {
        switch kind {
        case .downloads: "storage.stock"
        case .frames: "storage.images"
        case .channelsAndGuide: "cache.channels"
        case .episodeIndex: "cache.episodes"
        case .libraryLists: "cache.lists"
        case .diagnosticTraces: "cache.diagnostics"
        case .other: "storage.other"
        }
    }
}
