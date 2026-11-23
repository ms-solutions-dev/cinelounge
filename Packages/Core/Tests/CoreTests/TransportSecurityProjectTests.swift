import Foundation
import SourceProbe
import Testing

@testable import Core

/// The probe against the **real** project file of the TV — it stays with
/// `Core`, because the foundation (`Grundstock`) knows no project against which it could
/// check.
@Suite("Transport security of the project file")
struct TransportSecurityProjectTests {

    @Test("The real project file allows addresses like jellyfin.example")
    func actualProjectConfiguration() throws {
        // Reads the actual configuration, not a rebuilt one. Only that way
        // does one notice if somebody later combines the entries again.
        let yaml = try SourceText.read(.tvProject)

        // Look only at the entries themselves, not at the explanatory lines —
        // in the comments the names stand deliberately as a warning.
        let settings =
            yaml
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") }

        let hasArbitrary = settings.contains { $0.hasPrefix("NSAllowsArbitraryLoads:") }
        let overriding = TransportSecurityRule.overridingKeys.filter { key in
            settings.contains { $0.hasPrefix("\(key):") }
        }

        #expect(hasArbitrary, "NSAllowsArbitraryLoads is missing — name addresses would be blocked")
        #expect(
            overriding.isEmpty,
            """
            \(overriding.joined(separator: ", ")) sits next to NSAllowsArbitraryLoads \
            and makes it ineffective. Addresses like jellyfin.example then fail with \
            error -1022 before a connection is even established.
            """
        )

        // And for safety the same evaluation as in the system.
        var parsed: [String: Bool] = [:]
        if hasArbitrary { parsed["NSAllowsArbitraryLoads"] = true }
        for key in overriding { parsed[key] = true }

        #expect(TransportSecurityRule.evaluate(parsed).permitsCustomDomainNames)
    }
}
