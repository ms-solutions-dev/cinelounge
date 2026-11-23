import Core
import Testing

@testable import ParentalControls

/// **Which limit applies to this person on this device** — AP45, 2026-09-24.
///
/// The sentence "the stricter of both applies — person and device" had been in the
/// DocC since AP41, but the computation for it did not exist: Whoever passed `forItem:` got the limit of the profile
/// and **lost that of the device**; whoever left it out got that of the device for everyone.
@Suite("The effective age limit")
struct EffectiveLimitTests {

    /// **Stricter means smaller.** "From 6" blocks more than "from 18".
    @Test("Of two limits the smaller applies")
    func smallerWins() {
        #expect(AgeLimit.forItem(profile: .from6, device: .from18) == .from6)
        #expect(AgeLimit.forItem(profile: .from18, device: .from6) == .from6)
    }

    /// **`nil` means "no question" and loses against every number.**
    ///
    /// That is the case in question: A profile without a limit of its own on a device for
    /// which one is set — the TV in a child's room. If only the profile were read,
    /// the lock would be open.
    @Test("A missing limit loses against an existing one")
    func missingLoses() {
        #expect(AgeLimit.forItem(profile: nil, device: .from12) == .from12)
        #expect(AgeLimit.forItem(profile: .from12, device: nil) == .from12)
    }

    @Test("Without both there is no limit")
    func withoutEitherNone() {
        #expect(AgeLimit.forItem(profile: nil, device: nil) == nil)
    }

    /// **And the same from the store.** The path there is the one the filter takes.
    @Test("From the store the stricter of both keys applies")
    func fromStore() {
        let bucket = InMemoryStore()
        AgeLimit.write(.from18, in: bucket, forItem: nil)
        AgeLimit.write(.from6, in: bucket, forItem: "selin")

        #expect(AgeLimit.applicable(from: bucket, forItem: "selin") == .from6)
        // For a profile without one of its own, the device base level applies.
        #expect(AgeLimit.applicable(from: bucket, forItem: "max") == .from18)
        // And without a profile likewise — that is the state before the first sign-in.
        #expect(AgeLimit.applicable(from: bucket, forItem: nil) == .from18)
    }

    /// **The case that without this computation would have been a silent opening.**
    ///
    /// The only screen that sets a limit writes it to the **device**.
    /// Had the filter read only per profile, every limit set there would have become
    /// ineffective — and without any message, because "no limit" looks like
    /// "nothing set".
    @Test("A limit set on the device applies to every profile")
    func deviceLimitStillApplies() {
        let bucket = InMemoryStore()
        AgeLimit.write(.from12, in: bucket, forItem: nil)

        #expect(AgeLimit.applicable(from: bucket, forItem: "wer-auch-immer") == .from12)
    }
}
