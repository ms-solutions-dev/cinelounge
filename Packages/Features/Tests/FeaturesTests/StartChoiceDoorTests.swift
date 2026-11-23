import Foundation
import SourceProbe
import Testing

@testable import Features

/// **"Start automatically as …" must not be a back door** — AP45, 2026-09-23.
///
/// **Found while building the setting, not while testing afterwards.**
/// ``ProfileKit/StartChoice`` does not bypass a PIN — but the PIN it checks
/// is that **of the target profile**. An adult profile often has none at all; the
/// household is then protected via ``ParentalControlsState`` and not via the profile.
///
/// **The path that would otherwise stand open** is two steps long and needs no digit:
/// a child opens the profile list, sets "start automatically as a parent" and
/// restarts the TV. Afterwards the child sits there without any limit — and nobody
/// notices, because the device does exactly what it is supposed to.
///
/// **The door is called `accountSwitch`**, and its own sentence in ``LockedDoors`` says
/// why: *"An account switch removes every limit."* The start choice is an account switch
/// with a delay.
@Suite("The start choice sits behind the door")
struct StartChoiceDoorTests {

    @Test("The button asks parental controls")
    func behindTheDoor() throws {
        let content = try SourceText.read("ProfileView.swift", in: .features)

        // The body of the button: from its identifier to the closing brace of the
        // `guard`. Three lines suffice — if the lock is not there, it is nowhere.
        guard let anchor = content.range(of: #"identifier: "startwahl""#) else {
            Issue.record("The button for the start choice is missing in ProfileView.")
            return
        }
        let bodyContent = content[anchor.upperBound...].prefix(220)

        #expect(
            bodyContent.contains(#"lock.isAllowed(finished: "kontowechsel")"#),
            """
            The start-choice button does not ask parental controls. A child can use it to set \
            “start automatically as a parent” and restart — afterwards it sits there \
            without a limit, and the device does exactly what is configured.
            """)
    }
}
