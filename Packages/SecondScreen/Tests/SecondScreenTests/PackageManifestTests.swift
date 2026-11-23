import Foundation
import SourceProbe
import Testing

@testable import SecondScreen

/// **The manifest says what is in this package — and it said the wrong thing.**
///
/// AP22, 2026-09-11. `Package.swift` claimed that the contracts `Command`,
/// `StateMirror` and `RemoteKeyboard` "remain empty until someone builds them", while
/// they lay next to it, filled. That is the purest form of the silent failure: it does not
/// throw, it breaks nothing, it costs nobody a second of runtime — it costs the next
/// reader a second wire.
///
/// **A check against a comment is unusual, and here it is right.** A package manifest is
/// the first file opened by someone who does not know the package; this one sentence stood
/// there wrong for thirteen commits because nobody read it again. What is checked here is
/// therefore not the wording but the **claim**: if the manifest says something is empty,
/// it has to be empty.
@Test("The package manifest claims nothing about empty contracts that are filled")
func manifestDoesNotLieAboutContracts() throws {
    let manifest = try SourceText.read(.secondScreenManifest)

    for (fileName, name) in [
        ("Command", "Command"), ("StateMirror", "StateMirror"),
        ("RemoteKeyboard", "RemoteKeyboard"),
    ] {
        let content = try SourceText.read("\(fileName).swift", in: .secondScreen)

        // Filled means: more than the header. A file with `import Foundation` and an empty
        // declaration would be the state the old sentence described.
        let rows = content.split(separator: "\n").count
        #expect(rows > 20, "\(fileName).swift has only \(rows) lines")

        #expect(
            manifest.contains(name),
            "\(name) is in the tree, but not in the manifest — whoever looks for it does not find it")
    }

    #expect(
        !manifest.contains("stehen weiter leer"),
        """
        The manifest says the contracts are empty — they are filled next to it. \
        This very sentence caused the wire to be searched a second time.
        """
    )
}

/// **The one reservation that really applies is stated there too.**
///
/// ``RemoteKeyboard`` is built and checked, but attached to no input field: `signIn` and
/// `signOut` have zero callers. A manifest that, when correcting, turned "everything
/// empty" into "everything done" would have the same error with the opposite sign — and
/// the next reader would look in vain for the connection.
@Test("The reservation about the remote keyboard is in the manifest and points to its package")
func manifestNamesTheOpenPort() throws {
    let manifest = try SourceText.read(.secondScreenManifest)

    #expect(manifest.contains("RemoteKeyboard"))
    #expect(manifest.contains("AP24"), "the reservation needs a package, otherwise it is a note")
}
