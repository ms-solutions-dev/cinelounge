import Foundation

/// The licenses of the third-party packages — **read and not maintained.**
///
/// **Why at all** (AP26, 2026-09-11): Apple does not require third-party licenses, **the
/// licenses themselves do.** Apache 2.0 §4 and the MIT license both want the
/// notice and license text to be shipped.
///
/// **A hand-maintained list drifts apart on the first day someone swaps a
/// package** — and unnoticed, because a wrong license list looks like
/// a right one. `scripts/licenses.py` therefore reads what actually travels along:
/// `Package.resolved` names the resolved packages including their version,
/// `.dd/SourcePackages/checkouts/` holds their license files.
public enum Licenses {

    public struct Package: Sendable, Decodable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case name
            case version = "fassung"
            case location = "ort"
            case kind = "art"
            case text
            case addedLater = "nachgetragen"
        }

        public let name: String
        public let version: String
        /// The source — appears in the file and is not shown on the TV: an
        /// address nobody can click is a line without purpose.
        public let location: String
        /// `nil` if no license file was found for this package.
        public let kind: String?
        public let text: String?
        /// From which version of the slot the text comes, if the resolved state
        /// itself carries no license file.
        public let addedLater: String?

        /// What appears in the line on the right.
        ///
        /// **A gap is named and not concealed:** A package without a license file
        /// in its source is not a package without a license — it is one whose license someone
        /// has to add.
        public var kindOrGap: String { kind ?? "—" }
    }

    /// All packages, read once.
    ///
    /// **Empty if the file is missing** — and the view says so. An empty
    /// area without explanation would look like a drawing error.
    public static let all: [Package] = {
        guard let location = Bundle.main.url(forResource: "Lizenzen", withExtension: "json"),
            let data = try? Data(contentsOf: location),
            let read = try? JSONDecoder().decode([Package].self, from: data)
        else { return [] }
        return read
    }()
}
