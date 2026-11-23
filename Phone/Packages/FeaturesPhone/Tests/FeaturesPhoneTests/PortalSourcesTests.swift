import Foundation
import Testing

@testable import FeaturesPhone

/// A portal's source choice — **a flat list that answers three questions.**
///
/// **The test data have the shape of the real thing and not its content.** The names and the
/// number of rows were measured at the bridge on 2026-09-06; the IDs are invented,
/// because the real ones are full host URLs and do not belong in any source text.
@Suite("Portal sources")
struct PortalSourcesTests {

    /// Ten rows as the Ahorn Mediathek returns them: five tiers, each with and without
    /// audio description, no language.
    private static var ahorn: PortalSourceChoice {
        var rows: [PortalHost] = []
        for (slot, tier) in ["HD 1080p", "HD 720p", "SD 540p", "SD 360p", "Auto"].enumerated() {
            rows.append(PortalHost(id: "a\(slot)", name: tier))
            rows.append(
                PortalHost(id: "a\(slot)d", name: "\(tier) · Audiodeskription"))
        }
        return PortalSourceChoice(rows)
    }

    /// Twelve rows as Animehub returns them: four hosts times three versions.
    private static func anime(locked: Set<String> = []) -> PortalSourceChoice {
        var rows: [PortalHost] = []
        for (slot, name) in ["HOSTA", "Hosth", "Klenvauk", "Ditstokrais"].enumerated() {
            for (location, version) in ["(DE)", "(JPN) Sub: (EN)", "(JPN) Sub: (DE)"].enumerated() {
                let isBlocked = locked.contains(name)
                rows.append(
                    PortalHost(
                        id: "h\(slot)-\(location)", name: name, language: version,
                        locked: isBlocked,
                        reason: isBlocked ? "Vom Server gesperrt" : nil))
            }
        }
        return PortalSourceChoice(rows)
    }

    // MARK: - Die Zerlegung

    /// **The core of the finding:** Four hosts stand there flat as twelve rows, and three
    /// of them have the same name. What is up for choice is four times three.
    @Test("Twelve rows break down into four providers and three versions")
    func animeDecomposition() {
        let choice = Self.anime()
        #expect(choice.rows.count == 12)
        #expect(choice.provider == ["HOSTA", "Hosth", "Klenvauk", "Ditstokrais"])
        #expect(choice.variants == ["(DE)", "(JPN) Sub: (EN)", "(JPN) Sub: (DE)"])
        // **No provider is a tier** — the opposite direction, without which the test suite
        // would claim only half.
        #expect(choice.slots.isEmpty)
    }

    /// With the Ahorn it is the other way round: tiers and an addendum, no provider.
    @Test("The AHORN rows break down into five tiers and one addendum")
    func ardDecomposition() {
        let choice = Self.ahorn
        #expect(choice.slots == ["HD 1080p", "HD 720p", "SD 540p", "SD 360p", "Auto"])
        #expect(choice.variants == ["Audiodeskription"])
        #expect(choice.provider.isEmpty)
    }

    /// **The detection is narrow, and what it does not detect stays selectable.**
    @Test("A number with p and the word Auto are tiers, a name is not")
    func tierDetection() {
        #expect(PortalHost(id: "x", name: "HD 1080p").isTier)
        #expect(PortalHost(id: "x", name: "SD 360p").isTier)
        #expect(PortalHost(id: "x", name: "Auto").isTier)
        #expect(!PortalHost(id: "x", name: "Hosth").isTier)
        #expect(!PortalHost(id: "x", name: "Hostd").isTier)
        // An unknown name counts as a provider — the safe direction: It stays
        // visible and selectable instead of disappearing from the provider choice.
        #expect(PortalHost(id: "x", name: "4K").provider == "4K")
    }

    /// The version comes from two fields, depending on which one the portal fills.
    @Test("The version is the language, otherwise the addendum after the dot")
    func versionFromTwoFields() {
        #expect(PortalHost(id: "x", name: "HOSTA", language: "(DE)").version == "(DE)")
        #expect(
            PortalHost(id: "x", name: "SD 540p · Audiodeskription").version
                == "Audiodeskription")
        #expect(PortalHost(id: "x", name: "Auto").version == nil)
    }

    // MARK: - What becomes selectable from it

    @Test("Provider and version together hit exactly one row")
    func hitInCrossProduct() {
        let choice = Self.anime()
        let match = choice.match(provider: "Klenvauk", version: "(JPN) Sub: (DE)")
        #expect(match?.name == "Klenvauk")
        #expect(match?.language == "(JPN) Sub: (DE)")
    }

    /// **A locked row stays and only becomes unselectable** — with the bridge's reason,
    /// verbatim.
    @Test("A locked provider is in the list but is not a target")
    func lockedOneStays() {
        let choice = Self.anime(locked: ["Hosth"])
        let suggestions = choice.suggestions(forItem: .provider)
        #expect(suggestions.count == 4)

        let dood = suggestions.first { $0.value == "Hosth" }
        #expect(dood?.selectable == false)
        #expect(dood?.reason == "Vom Server gesperrt")

        // The opposite direction: The other three are selectable and carry no reason.
        let other = suggestions.filter { $0.value != "Hosth" }
        #expect(other.allSatisfy { $0.selectable && $0.reason == nil })
    }

    /// **The protection against a button without effect**: What has no target is drawn
    /// dimmed — and `selectable` is exactly the information on which that hangs.
    @Test("No suggestion has a target that is locked")
    func noTargetIsLocked() {
        let choice = Self.anime(locked: ["HOSTA"])
        for field in PortalSourceChoice.Field.allCases {
            for suggestion in choice.suggestions(forItem: field) {
                #expect(suggestion.target?.locked != true)
            }
        }
    }

    /// A single row is not a choice — then the button in the player header is dropped.
    @Test("One row does not warrant a sheet, twelve do")
    func isWorthwhile() {
        #expect(!PortalSourceChoice([]).isWorthwhile)
        #expect(!PortalSourceChoice([PortalHost(id: "x", name: "HOSTA")]).isWorthwhile)
        #expect(Self.anime().isWorthwhile)
        #expect(Self.ahorn.isWorthwhile)
    }

    // MARK: - Die Uhr

    @Test("The remaining time shows as minutes and seconds")
    func clockTime() {
        #expect(SourceSheetPortal.clockTime(252) == "4:12")
        #expect(SourceSheetPortal.clockTime(60) == "1:00")
        #expect(SourceSheetPortal.clockTime(9) == "0:09")
    }

    /// **`nil` means unknown and not forever** — the rule on which the one-time
    /// refetch hangs.
    @Test("Without a deadline nothing has expired")
    func withoutDeadlineNotExpired() {
        let without = PlaybackRequest(
            identifier: "x", title: "x", address: URL(string: "https://beispiel.test/x")!)
        #expect(!without.isExpired())

        let using = PlaybackRequest(
            identifier: "x", title: "x", address: URL(string: "https://beispiel.test/x")!,
            validUntil: Date(timeIntervalSince1970: 0))
        #expect(using.isExpired())
    }
}
