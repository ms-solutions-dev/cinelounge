import Foundation

/// An entry in the error book.
///
/// `Codable`, because the book lies on disk as one line of JSON per entry: a
/// file that is only appended to survives a crash in the middle of writing — then the last
/// line is missing and not the file.
public struct ContentEntryRecord: Sendable, Codable, Equatable, Identifiable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp = "zeitpunkt"
        case area = "bereich"
        case severity = "schwere"
        case message = "satz"
    }

    public let id: UUID
    public let timestamp: Date
    public let area: Area
    public let severity: Severity

    /// The sentence. Already redacted — what stands here may go out.
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        area: Area,
        severity: Severity,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.area = area
        self.severity = severity
        self.message = message
    }

    /// The line in the report.
    ///
    /// Time, area, symbol, sentence — in fixed width, so that one can read the
    /// column when skimming instead of every line.
    public var row: String {
        let time = ContentEntryRecord.clock.string(from: timestamp)
        let character =
            switch severity {
            case .step: "·"
            case .hint: "!"
            case .error: "✗"
            case .abort: "✗✗"
            }
        return "\(time)  \(area.tag)  \(character)  \(message)"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM. HH:mm:ss"
        f.locale = Locale(identifier: "de_DE")
        return f
    }()
}
