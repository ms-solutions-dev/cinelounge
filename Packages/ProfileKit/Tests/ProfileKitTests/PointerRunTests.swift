import Core
import Foundation
import Testing

@testable import ProfileKit

/// **Whoever switches the profile pointer does so in a run of their own** — 2026-09-23.
///
/// **The finding came from a crash and not from a red line.** The
/// release build of the package ended in `SIGSEGV` in `_swift_release_dealloc`, on
/// a thread of the task pool, in the middle of ``ProfileSwitchTests``. Ten runs afterwards
/// were green; the crash report was the only witness.
///
/// **The cause is a race on a single cell.** ``Core/ProfilePointer`` holds the
/// active pointer as a `nonisolated(unsafe) static var` — with a justification: It is set
/// at startup and on switching, both on the main thread. **In the check run that does not hold.**
/// Swift Testing gives every check a task of its own and lets them run side by side;
/// every one that calls ``ProfileKit/ProfileSwitch/switchTo(zu:in:keychain:deviceStore:ledgerStore:)``
/// writes the same cell. A torn reference count on a `String?` is
/// exactly the crash that is in the report.
///
/// **The remedy has lain next to it since 2026-09-21 and was half applied:**
/// ``Core/ProfilePointer/als(_:_:)`` creates a pointer as a task value that applies only in
/// this check. Of eleven checks that switch, **two** used it — the
/// two that read the pointer afterwards. The other nine did not read it and
/// therefore wrote process-wide, without anyone noticing.
///
/// **This check reads source text and not behaviour**, because a race cannot be
/// demonstrated reliably: Ten green runs prove nothing. What can be verified is the rule
/// from which it followed.
@Test("Every check that switches the profile pointer runs in its own pointer")
func switchChecksRunInOwnPointer() throws {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }

    var raw: [String] = []
    for file in files {
        let rows = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Starts of all methods at the level of the type.
        let starts = rows.indices.filter {
            rows[$0].hasPrefix("    func ") || rows[$0].hasPrefix("    private func ")
                || rows[$0].hasPrefix("    static func ")
        }
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1] : rows.count
            let bodyContent = rows[start..<end].joined(separator: "\n")
            guard bodyContent.contains("ProfileSwitch.switchTo") else { continue }
            guard !bodyContent.contains("ProfilePointer.als") else { continue }
            let name = rows[start].split(separator: "(").first.map(String.init) ?? rows[start]
            raw.append("\(file.lastPathComponent):\(start + 1) \(name.trimmingCharacters(in: .whitespaces))")
        }
    }

    #expect(
        raw.isEmpty,
        """
        These checks switch the profile without their own pointer and so write \
        process-wide — run concurrently that is a race:
        \(raw.joined(separator: "\n"))
        """)
}
