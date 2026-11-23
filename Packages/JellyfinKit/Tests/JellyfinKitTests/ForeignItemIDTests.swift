import Foundation
import Testing

@testable import JellyfinKit

/// **When the media server is asked about a provider title, the call site is to blame —
/// and that must show in the log.**
///
/// The same mix-up slipped through twice. On 2026-08-15 the handoff to the player passed the
/// media server throughout, also for provider titles; on 2026-08-23 the path via the detail
/// page did it, which for the provider library did not even exist yet on 2026-08-15. Both
/// times the log said only:
///
/// ```
/// Sitzung erfragen …/Items/…%23movie%23339501%23mkv/PlaybackInfo  ✗ badRequest
/// ```
///
/// Correct, but silent about the fact that the **source** was wrong and not the request.
/// A `badRequest` sends the search to the server; the cause lay in the call.
@Suite("Recognizing a foreign title identifier")
struct ForeignItemIDTests {

    /// The real identifiers from the device diagnosis of 2026-08-23.
    @Test("Provider identifiers from the diagnostics are recognized")
    func realProviderIDs() {
        for id in [
            "35657D19-4FE3-46C7-8A84-91FB84B7EAF9#movie#339501#mkv",
            "35657D19-4FE3-46C7-8A84-91FB84B7EAF9#movie#333037#mkv",
            "35657D19-4FE3-46C7-8A84-91FB84B7EAF9#episode#315459#mp4",
            "35657D19-4FE3-46C7-8A84-91FB84B7EAF9#series#6879",
        ] {
            #expect(JellyfinSource.isForeignItemID(id), "not recognized: \(id)")
        }
    }

    /// And the media server's identifiers must **never** trigger — a false warning at every
    /// film start would be worse than none.
    @Test("Server identifiers do not trigger")
    func serverIDsStaySilent() {
        for id in [
            "67ac5ed0436897b1361ec82f3f03fdae",
            "700e8818d9ff7cbad6d399f0e7f0d01c",
            "5784114208bda2aad36d7282719702fa",
            // Also the spelling with hyphens that Jellyfin emits in some places.
            "67ac5ed0-4368-97b1-361e-c82f3f03fdae",
        ] {
            #expect(!JellyfinSource.isForeignItemID(id), "falsely reported: \(id)")
        }
    }
}
