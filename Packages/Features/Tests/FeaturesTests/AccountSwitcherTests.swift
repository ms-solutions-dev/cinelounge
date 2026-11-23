import Foundation
import ProfileKit
import Testing

@testable import Features

/// **Where the profile icon leads** (2026-09-13). The sheet "Wer schaut?" replaces the jump
/// into the settings — with one exception, which stands with its reason at
/// ``AccountSwitcher/route(parentalControlsApply:)``.
@Suite("The account switcher")
struct AccountSwitcherTests {

    /// **Also with a single account.** The first draft then jumped into the settings, and the
    /// report was only: "still opens Settings". An icon that does something different depending
    /// on the number of accounts cannot be learned.
    @Test("Without parental controls always the sheet")
    func sheet() {
        #expect(AccountSwitcher.route(parentalControlsApply: false) == .sheet)
    }

    /// The door stands in front of the sheet and no longer in the settings (AP59 N3) — one used
    /// to end up in the "Jellyfin" section there.
    @Test("With parental controls, the door stands in front of the sheet")
    func parentalControls() {
        #expect(AccountSwitcher.route(parentalControlsApply: true) == .sheetBehindDoor)
    }
}

/// **A press that is followed by nothing** — AP45, 2026-09-23.
///
/// Until today ``AccountSwitcher/select(_:)`` simply stopped at a profile with its own PIN:
/// *"If the target carries a PIN, nothing happens here. The latch sits in
/// ``ProfileKit/ProfileSwitch``; the number pad for it comes with AP45. Until then the lock
/// holds instead of opening to be on the safe side."*
///
/// **The direction was right and the effect wrong all the same.** On screen, a lock that
/// stays silent cannot be told from a broken button — and the circle carries no padlock that
/// would explain the difference. Whoever knows the PIN takes the device for defective;
/// whoever does not know it never learns that there is one.
@Suite("The account switcher asks for the PIN")
struct AccountSwitcherPinTests {

    @Test("A locked target leads to the number pad")
    func pinRequired() {
        #expect(AccountSwitcher.reply(to: .pinRequired) == .pin)
    }

    /// **A failed switch does not lead to the pad.** Otherwise the number pad would stand in
    /// front of a profile that does not exist — and every number entered would be wrong without
    /// anyone being able to say why.
    @Test("An unknown target leads nowhere")
    func unknown() {
        #expect(AccountSwitcher.reply(to: .unknown) == .nothing)
    }
}

/// **Pressing one's own profile closes "Wer schaut?"** (on-device test 2026-09-30): At launch
/// the own profile stood preselected, the press on it did nothing, and the sheet closed only
/// with "Back".
@Suite("Who is watching: the own profile")
struct OwnProfileTests {

    private let max = Profile.Identifier(rawValue: "max")
    private let otherProfile = Profile.Identifier(rawValue: "sina")

    @Test("The own profile closes without switching")
    func ownCloses() {
        #expect(AccountSwitcher.press(to: max, active: max) == .close)
    }

    @Test("Another profile switches")
    func otherSwitches() {
        #expect(AccountSwitcher.press(to: otherProfile, active: max) == .wechseln)
    }

    @Test("Without an active profile every press switches")
    func withoutActive() {
        #expect(AccountSwitcher.press(to: max, active: nil) == .wechseln)
    }
}
