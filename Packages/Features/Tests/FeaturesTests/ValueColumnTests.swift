import Foundation
import Testing

@testable import Features

/// **The value column sits on the row** (AP46, 2026-09-25) — "46 of 79", "3 · Alex",
/// "hidden".
///
/// **Not in the section list**, and that is measured: There 264 pt remain for the label,
/// the widest entry measures 229. The value belongs on the ``DisclosureRow``, which
/// has accepted it since 2026-09-23 — and a ``DisclosureRow`` without a value demands a
/// press just to learn what is behind it. Exactly the disadvantage the column
/// abolishes.
///
/// **The value is mandatory except for justified exceptions**, and the exceptions stand here
/// with their reason — like ``SettingsCardTests/withoutCard``.
@Suite("The value column on the rows")
struct ValueColumnTests {

    /// ``DisclosureRow`` rows behind which there is **no state** that a value could name.
    static let withoutValue: [String: String] = [
        "zustandsschau": "a debugging tool; it produces failures and has no state of its own",
        // Other devices (AP59 N7): Both open a procedure with a code, not a status.
        "vomHandy": "an action — receiving shows its code only on opening",
        "fernkopplung": "an action — the pairing code is created only on opening",
    ]

    /// Every call of `DisclosureRow(` with its identifier and whether it carries a value.
    static func callCount() throws -> [(file: String, identifier: String, hasValue: Bool)] {
        var discoveries: [(String, String, Bool)] = []
        for (file, content) in try FocusPlan.sourceTexts() where file != "SettingsRows.swift" {
            var rest = content[...]
            while let match = rest.range(of: "DisclosureRow(") {
                var depth = 0
                var location = rest.index(before: match.upperBound)
                while location < rest.endIndex {
                    if rest[location] == "(" { depth += 1 }
                    if rest[location] == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    location = rest.index(after: location)
                }
                let call = String(rest[match.lowerBound..<location])
                let identifier =
                    call.firstMatch(of: /identifier:\s*"([^"]*)"/).map { String($0.output.1) } ?? "?"
                discoveries.append((file, identifier, call.contains("value:")))
                rest = rest[location...]
            }
        }
        return discoveries
    }

    @Test("Every forward row says what is behind it")
    func everyRowCarriesItsValue() throws {
        let callCount = try Self.callCount()
        #expect(
            callCount.count >= 10,
            "only \(callCount.count) forward rows found — the reading does not take hold")
        for (file, identifier, hasValue) in callCount where !hasValue && Self.withoutValue[identifier] == nil
        {
            Issue.record(
                """
                \(file): forward row “\(identifier)” without a value. What is behind it — a number, \
                a name, a state? Otherwise the information costs a press.
                """)
        }
    }

    @Test("Every exception points to a row that exists")
    func exemptionsAreCurrent() throws {
        let identifiers = Set(try Self.callCount().map(\.identifier))
        for identifier in Self.withoutValue.keys where !identifiers.contains(identifier) {
            Issue.record("“\(identifier)” is listed in `withoutValue` but no longer exists")
        }
    }
}
