import Core
import Foundation
import ParentalControls
import ProfileKit
import Testing

@testable import Features

/// The profile picture on the TV (AP49): choice in the sheet, path into the book, picture or letter.
@MainActor
@Suite("The profile picture on the TV")
struct ProfilePictureTests {

    typealias Saved = (
        name: String, color: Profile.ColorTag, kind: Profile.Kind, limit: AgeLimit?,
        avatar: String?
    )

    static func draft(avatar: String?, name: String = "Oma") -> ProfileSheet.Draft {
        ProfileSheet.Draft(
            name: name, color: .moss, kind: .adult, limit: nil, avatar: avatar)
    }

    // MARK: - The sheet

    /// **The connection that cannot be seen on screen:** the preview shows the picture
    /// from the draft — whether it goes along when saving, it does not show.
    @Test("The picture choice goes to onSave")
    func choiceComesAlong() {
        var backedUp: [Saved] = []
        let ok = Self.draft(avatar: "strick-oma").save { backedUp.append(($0, $1, $2, $3, $4)) }
        #expect(ok)
        #expect(backedUp.count == 1)
        #expect(backedUp.first?.avatar == "strick-oma")
        #expect(backedUp.first?.name == "Oma")
    }

    @Test("\"No picture\" goes to onSave as nil")
    func noPictureComesAlong() {
        var backedUp: [Saved] = []
        Self.draft(avatar: nil).save { backedUp.append(($0, $1, $2, $3, $4)) }
        #expect(backedUp.count == 1)
        #expect(backedUp.first?.avatar == nil)
    }

    @Test("An empty name does not save even with a picture")
    func emptyName() {
        var called = false
        let ok = Self.draft(avatar: "strick-oma", name: "  ").save { _, _, _, _, _ in
            called = true
        }
        #expect(!ok)
        #expect(!called)
    }

    /// The rule from before AP49 stays: the limit goes along only for children.
    @Test("The limit goes along only for children")
    func limitOnlyForChildren() {
        var draft = Self.draft(avatar: nil)
        draft.limit = .from12
        var backedUp: [Saved] = []
        draft.save { backedUp.append(($0, $1, $2, $3, $4)) }
        draft.kind = .kind
        draft.save { backedUp.append(($0, $1, $2, $3, $4)) }
        #expect(backedUp.map(\.limit) == [nil, .from12])
    }

    @Test("The grid is four by four")
    func raster() {
        let rows = ProfileSheet.rows(AvatarMotif.all, columns: 4)
        #expect(rows.map(\.count) == [4, 4, 4, 4])
        #expect(rows.flatMap { $0 } == AvatarMotif.all)
        #expect(ProfileSheet.rows(AvatarMotif.all, columns: 0).isEmpty)
    }

    // MARK: - The circle

    @Test("Picture only with a known name and the picture in the bundle")
    func appearance() {
        let always: (String) -> Bool = { _ in true }
        #expect(AvatarMotif.appearance(avatar: nil, imageExists: always) == .letter)
        #expect(AvatarMotif.appearance(avatar: "", imageExists: always) == .letter)
        #expect(AvatarMotif.appearance(avatar: "drache-im-nebel", imageExists: always) == .letter)
        // **The second relapse:** the directory knows the name, the bundle does not.
        #expect(AvatarMotif.appearance(avatar: "strick-oma", imageExists: { _ in false }) == .letter)
        let motif = AvatarMotif.motif(forItem: "strick-oma")
        #expect(motif != nil)
        if let motif {
            #expect(AvatarMotif.appearance(avatar: "strick-oma", imageExists: always) == .image(motif))
        }
    }

    /// On the Mac there is no app bundle with avatars — there the circle draws the
    /// letter, and the tests see exactly that.
    @Test("Without a bundle no picture")
    func withoutBundle() {
        #expect(!AvatarMotif.inAppBundle("strick-oma"))
    }

    // MARK: - Who's watching?

    @Test("The title picture follows the focus and stays on the actions")
    func titleImage() {
        let profile = ["a", "b"]
        #expect(AccountSwitcher.titleID(focus: "b", profile: profile, previous: "a") == "b")
        #expect(
            AccountSwitcher.titleID(focus: "verwalten", profile: profile, previous: "b") == "b")
        #expect(AccountSwitcher.titleID(focus: nil, profile: profile, previous: "a") == "a")
    }

    // MARK: - Into the ledger

    @Test("Creating and changing write the picture into the book")
    func intoLedger() throws {
        let bucket = InMemoryStore()
        let model = ProfileModel(
            keychain: SecureStore(service: "probe.\(UUID().uuidString)"), store: bucket)

        let identifier = try #require(
            model.create(name: "Oma", color: .moss, kind: .adult, avatar: "strick-oma"))
        #expect(ProfileBook.read(from: bucket).profile.first?.avatar == "strick-oma")

        model.update(identifier, name: "Oma", color: .moss, avatar: "opa-teekanne")
        #expect(ProfileBook.read(from: bucket).profile.first?.avatar == "opa-teekanne")

        model.update(identifier, name: "Oma", color: .moss, avatar: nil)
        #expect(ProfileBook.read(from: bucket).profile.first?.avatar == nil)
    }
}
