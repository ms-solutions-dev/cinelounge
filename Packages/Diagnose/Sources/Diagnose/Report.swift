import Core
import Foundation

/// A report: ID, device, and what is in the book.
///
/// The **readable ID** comes from `Core.DiagnosticID` — six characters from an
/// alphabet without confusable characters, in the format `XXXX-XX`. That way someone on the
/// phone can say which report they mean without having to spell out a UUID.
public struct Report: Sendable {

    public let identifier: String
    public let createdAt: Date
    public let device: DeviceDetails
    public let entries: [ContentEntryRecord]

    public init(
        identifier: String = DiagnosticID.fresh(),
        createdAt: Date = .now,
        device: DeviceDetails,
        entries: [ContentEntryRecord]
    ) {
        self.identifier = identifier
        self.createdAt = createdAt
        self.device = device
        self.entries = entries
    }

    /// The report as text.
    ///
    /// The ID stands **at the top** so that it does not have to be searched for when read aloud, and
    /// in the form that `DiagnosticID.fromReport` finds again.
    public var text: String {
        var rows = [DiagnosticID.headerLine(identifier), ""]
        rows += device.rows
        rows += ["", "\(entries.count) entries", ""]
        rows += entries.map(\.row)
        return rows.joined(separator: "\n")
    }
}
