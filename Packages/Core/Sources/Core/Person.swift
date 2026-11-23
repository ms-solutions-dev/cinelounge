import Foundation

/// A contributing person — actor, voice actor, director.
///
/// For anime these are mostly voice actors, and the role there is the more
/// interesting piece of information than the name: "Spautrol Riaskupit" says more than
/// "Spehaugrut Zianoum".
public struct Person: Sendable, Equatable, Hashable, Identifiable, Codable {

    public enum Role: String, Sendable, Equatable, Hashable, Codable {
        case actor
        case director
        case writer
        case producer
        case composer
        case other

        public init(rawValue: String) {
            switch rawValue.lowercased() {
            case "actor": self = .actor
            case "director": self = .director
            case "writer": self = .writer
            case "producer": self = .producer
            case "composer", "musiccomposer": self = .composer
            default: self = .other
            }
        }

        /// Whether the person appears in the cast bar. Production and music rarely interest
        /// people in the living room — the director does.
        public var isProminent: Bool {
            self == .actor || self == .director
        }
    }

    public let id: String
    public let name: String
    public let role: Role
    /// The character played, if on file.
    public let character: String?
    /// Whether a picture is present — without one the entry is hardly worthwhile.
    public let hasImage: Bool

    public init(
        id: String,
        name: String,
        role: Role,
        character: String? = nil,
        hasImage: Bool = false
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.character = character
        self.hasImage = hasImage
    }
}
