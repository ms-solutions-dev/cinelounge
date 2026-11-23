import Core
import Diagnose
import Foundation
import JellyfinKit
import ParentalControls

/// Where the "Age ratings" sheet gets its raw texts.
///
/// **Raw texts with repetitions and not a set.** "TV-MA (31 titles)" is the number that
/// makes an assignment worthwhile; a de-duplicated list would have the raw text and not its
/// weight, and then "NR" would stand as large as "TV-MA".
///
/// **Does not throw.** A catalog that does not answer is not an exceptional case here: the
/// sheet then shows what the others have yielded, and an exception would take everything with it.
public protocol ApprovalsSource: Sendable {
    func approvals() async -> [String?]
}

/// The ratings of the media server — **once across every library.**
///
/// **One fetch per library and not per title.** Jellyfin delivers the rating in
/// the same response as the title; a fetch of its own for it would be, with 32,000 titles,
/// 32,000 requests for a string that was already there.
///
/// **Only the media server, and that is a statement.** Channels carry no age rating,
/// and the portals deliver none — there is nothing to assign for them here, and the sheet
/// says so in a row of its own instead of showing an empty list.
public struct JellyfinApprovalsSource: ApprovalsSource {

    private let source: any ContentSource

    public init(source: any ContentSource) {
        self.source = source
    }

    public func approvals() async -> [String?] {
        guard let libraries = try? await source.libraries() else { return [] }
        var collected: [String?] = []
        for library in libraries {
            // **One after another and not concurrently.** Six simultaneous full fetches
            // against the same server were, in the diagnostics report, the situation in which it stops
            // answering — and this sheet is in no hurry.
            guard
                let title = try? await source.items(
                    in: library.id, filter: ItemFilter(limit: Self.atMost))
            else {
                Diagnose.step(.surface, "Approvals: \(library.id) did not reply")
                continue
            }
            collected.append(contentsOf: title.map(\.ageRating))
        }
        return collected
    }

    /// How many titles are counted per library.
    ///
    /// **An upper bound and no completeness — and the sheet says so too.** The
    /// question this sheet answers is "which spellings occur", and it
    /// is answered after two thousand titles. A complete pass over six
    /// libraries costs minutes and changes nothing in the answer that
    /// would influence an assignment.
    static let atMost = 2000
}
