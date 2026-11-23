import Core
import Foundation
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **The intro on the phone too** (decision 27, C16).
///
/// The rules (day, build, season, screen reader) are shared and checked in `Core`
/// (`IntroTests`, `IntroSeasonTests`). What stands here is what the phone takes of it — and that the
/// files from the one folder in the repo really end up in its bundle.
struct IntroPhoneTests {

    @Test("On the phone only the clip, never the still frame")
    func clipOnly() {
        #expect(PhoneIntro.shows(.clip))
        #expect(!PhoneIntro.shows(.stillFrame))
        #expect(!PhoneIntro.shows(.none))
    }

    @Test("The phone project bundles the repo's intro folder, and every clip is in it")
    func filesInBundle() throws {
        let project = SourceText.strippingCommentLines(try SourceText.read(.phoneProject))
        let rows = project.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(rows.contains("- path: ../App/Resources/Intro"))

        let catalog = try IntroCatalog.read(
            Data(contentsOf: CodeLocation.tvIntro.url.appending(path: "intros.json")))
        let files =
            catalog.clips.map(\.file) + catalog.clips.compactMap(\.audio)
            + (catalog.seasons ?? []).flatMap { $0.clips.map(\.file) }
        for file in files {
            #expect(
                FileManager.default.fileExists(atPath: CodeLocation.tvIntro.url.appending(path: file).path),
                "\(file) is missing")
        }
    }
}
