import Foundation
import Testing

@testable import Core

/// The playback side of the diagnosis: the old names carry on, and the
/// fact sheet names engine and decoder.
@Suite("The playback trace on the ground")
struct PlaybackDiagnosticsTests {

    /// The switches that the viewer flips between channels
    /// (F-009): without them no finding can be assigned to a state.
    @Test("The profile sheet names engine and decoder")
    func reportHeaderCarriesTheSwitches() {
        let header = Diagnostics.reportHeader()
        #expect(header.count == 5)
        #expect(header[3].hasPrefix("Live engine: "))
        #expect(header[3].contains("own decoder: "))
        // Since 2026-09-28: both devices must name the same iCloud environment.
        #expect(header[4].hasPrefix("iCloud environment: "))
    }
}
