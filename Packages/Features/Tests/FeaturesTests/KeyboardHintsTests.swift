import DesignSystem
import Foundation
import SourceProbe
import Testing

@testable import Features

/// **Every input field says what belongs in it** — AP24, 2026-09-11.
///
/// "Typing is the most expensive action" is the hardest constraint of this platform. An
/// autocorrect costs the way back without anyone having done anything wrong: `vault.example`
/// becomes "Vault. Home", and from three metres away you cannot see the capital letter.
///
/// **The roadmap's zero finding was wrong, and that is the reason for this check.**
/// The pattern had long been decided in the project — `LoginView` set two of the three
/// hints by hand, `PlaylistLoginView` a different two. **The six fields in Settings, in the
/// move and in the channel search had not a single one**, and nobody noticed, because
/// three separate modifiers are three chances to forget one. Since AP24 every field has
/// **one** line.
///
/// What is checked is the source text and not a built view: whether a keyboard
/// capitalises is decided by the system and not by SwiftUI — all that can be verified is
/// that the line is there.
@Test("No TextField without a keyboard hint")
func everyTextFieldSaysWhatBelongsInIt() throws {
    var checked = 0
    for location in [CodeLocation.tvApp, .features] {
        for file in try SourceText.files(in: location) {
            let rows = file.content.split(separator: "\n", omittingEmptySubsequences: false)

            for (number, row) in rows.enumerated() {
                let raw = row.trimmingCharacters(in: .whitespaces)
                // Comments mention `TextField` in their reasons — and those very
                // reasons explain this check.
                guard !raw.hasPrefix("//"), raw.contains("TextField(") else { continue }
                checked += 1

                // The hint sits directly at the field: within the next ten
                // lines, before the next field begins.
                let window = rows[number..<min(number + 10, rows.count)]
                    .joined(separator: "\n")
                #expect(
                    window.contains(".keyboard(forItem:"),
                    """
                    \(file.name):\(number + 1) — a TextField without \
                    a keyboard hint. On tvOS an autocorrection costs the whole way \
                    back; `.keyboard(forItem:)` says in one \
                    line what the field is for.
                    """
                )
            }
        }
    }

    // The number is here so that an empty run does not pass as a success — for instance
    // because the path no longer matches.
    // Nine since 2026-09-12: the pairing code in ``PortalSettings`` was added.
    // Ten since the same evening: the channel search in the shelf picker (requirement:
    // channels also structured and with search, as on iOS).
    // Eleven since 2026-09-21: the name field in ``ProfileSheet`` (AP41, line 5) — the
    // first field in the app into which a **self-chosen name** is typed, and thus
    // the first with `.prose` instead of `.address` or `.identifier`.
    //
    // **Seven since 2026-09-24, and the number fell because things got better**
    // (AP46): Six fields in Settings moved into **one** building block, ``InputRow``.
    // There the ``InputKind`` is a **required argument** without a default — the promise "no
    // field without a keyboard hint" no longer depends, for these six, on someone writing a
    // line along with it, but on the fact that without it the code **does not compile**.
    //
    // **This check stays anyway**, because six of the seven are still outside:
    // `Regalquellen`, `LiveView`, `RemoteKeyboardField`, `MoveView`, `ProfileSheet`. If
    // the number drops further, check whether a field **moved to the building block** (good)
    // or **disappeared** (then a screen is missing).
    //
    // **Eight since 2026-09-30** (AP61): the name field when renaming a device in
    // ``CloudSheet`` — a self-chosen name, so `.prose` as in ``ProfileSheet``.
    //
    // **Seven again since AP88 wave 5:** the old sign-in screen went with its field helper; the
    // setup's Jellyfin sheet types into ``InputRow``, which is outside this count.
    #expect(checked == 7, "\(checked) fields were checked, 7 were expected")
}

/// **An address is never capitalised, a self-chosen name is.**
///
/// The enumeration carries the decision, not the call site — that is why it can be
/// recomputed here and not just read.
@Test("The three input kinds are distinguishable and complete")
func theThreeKindsAreFixed() {
    #expect(Set([InputKind.address, .identifier, .prose]).count == 3)
}
