import Foundation
import SourceProbe
import Testing

@testable import SecondScreen

/// **A service the Info.plist does not know does not register** — and says nothing while
/// doing so. AP24, 2026-09-11.
///
/// **The finding that triggered this file.** `App/Info.plist` and
/// `CineLounge.xcodeproj` are generated from `project.yml` and are in `.gitignore`; until
/// 2026-09-11 nobody did that automatically, and `xcodebuild` builds what is there. On 2026-09-10.
/// `_cinelounge-remote._tcp` went into `project.yml` at 16:26 — the generated `Info.plist`
/// was from 11:30. **The remote's Bonjour service was therefore in not a single build**,
/// the phone found nothing, and both sides stayed silent.
///
/// **That is why the source is checked here and not the product.** The generated files are
/// not checked in; a check against them would come up empty on every fresh clone.
/// `project.yml` is the truth, and `scripts/check.sh` has ensured since the same day that
/// the product follows it.
@Test("Every Bonjour service in the source is listed in project.yml")
func everyServiceIsInProjectFile() throws {
    let yaml = try SourceText.read(.tvProject)

    // Only the entries, not the explanatory lines: the comments deliberately repeat the
    // names.
    let entries =
        yaml
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.hasPrefix("#") }

    for service in [HandoffWire.service, DeviceDiscovery.service] {
        #expect(
            entries.contains { $0.contains(service) },
            """
            \(service) is missing in project.yml under NSBonjourServices. Without the entry \
            the service does not register at all — the phone finds nothing, and \
            it does so without an error message on either side.
            """
        )
    }

    // **And the permission for it.** Since tvOS 14, even the first connection into the local
    // network triggers the system prompt; without this entry it does not appear, and the
    // search knocks on nothing. That is the same silent failure with the opposite sign.
    #expect(entries.contains { $0.hasPrefix("NSLocalNetworkUsageDescription:") })
}

/// **The two services stay separate.**
///
/// One carries a one-time, encrypted procedure, the other holds a connection for hours and
/// speaks a different format. Running both through one service would mean touching the
/// verified handoff receiver at a spot where it is demonstrably correct today — the
/// reasoning is recorded this way in `project.yml`.
@Test("Handoff and remote have different services")
func twoServicesNotOne() {
    #expect(HandoffWire.service != DeviceDiscovery.service)
    // Both in the form Bonjour requires: type and protocol.
    for service in [HandoffWire.service, DeviceDiscovery.service] {
        #expect(service.hasPrefix("_"))
        #expect(service.hasSuffix("._tcp"))
    }
}
