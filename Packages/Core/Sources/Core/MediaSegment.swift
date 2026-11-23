import Foundation

/// A marked section within an episode — intro, outro, recap or preview. The server
/// determines these boundaries itself; the app fades in a button from them at the
/// right time.
public struct MediaSegment: Sendable, Equatable, Identifiable {

    public enum Kind: String, Sendable, Equatable {
        case intro
        case outro
        case recap
        case preview
        case commercial
        case unknown

        public init(rawValue: String) {
            switch rawValue.lowercased() {
            case "intro": self = .intro
            case "outro": self = .outro
            case "recap": self = .recap
            case "preview": self = .preview
            case "commercial": self = .commercial
            default: self = .unknown
            }
        }

        /// Whether skipping can be offered. Advertising is not offered — a library of one's
        /// own has none.
        public var isSkippable: Bool {
            switch self {
            case .intro, .outro, .recap: true
            case .preview, .commercial, .unknown: false
            }
        }
    }

    public let id: String
    public let kind: Kind
    public let start: TimeInterval
    public let end: TimeInterval

    public init(id: String, kind: Kind, start: TimeInterval, end: TimeInterval) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end - start) }

    /// Whether a point in time lies in this section. The end no longer counts toward
    /// it, otherwise two adjoining sections overlap by exactly one moment.
    public func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

extension Array where Element == MediaSegment {

    /// The section for which a button is to be shown right now.
    ///
    /// Very short sections are passed over: a button that flashes up for two seconds
    /// cannot be hit in the living room and disturbs more than it helps.
    public func skippable(at time: TimeInterval, minimumDuration: TimeInterval = 4) -> MediaSegment? {
        first { $0.kind.isSkippable && $0.duration >= minimumDuration && $0.contains(time) }
    }

    /// The outro, if present — the offer of the next episode depends on it.
    public var outro: MediaSegment? {
        first { $0.kind == .outro }
    }
}
