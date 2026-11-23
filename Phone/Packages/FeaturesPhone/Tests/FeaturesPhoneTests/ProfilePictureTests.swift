import Core
import Foundation
import ProfileKit
import SourceProbe
import SwiftUI
import Testing

@testable import FeaturesPhone

/// **AP49, stage 3 — profile pictures on the phone.**
///
/// The check that this is really about is the first: **The choice arrives in the profile ledger.**
/// It takes the path the Save button takes — ``ProfilePictureChoice`` from the profile,
/// ``ProfilePictureChoice/select(_:)``, ``ProfilePictureState/save(_:)`` — and then reads the
/// ledger from the store, not from the holder. A preview that shows the image while
/// what was there before is saved would not be visible on screen.
@MainActor
@Suite("Profile pictures on the phone")
struct ProfilePictureTests {

    private static let server = URL(string: "http://vault.beispiel:8096")!

    private static func account(_ user: String) -> Account.Identifier {
        Account.Identifier(server: server.absoluteString, user: user)
    }

    /// A ledger with two people, each with their media server user.
    private static func ledger(active: String) -> (InMemoryStore, max: Profile, kind: Profile) {
        var max = Profile(name: "Max", color: .turquoise)
        max.create(.jellyfin(server: server, userID: "u-max", username: "max"))
        var kind = Profile(name: "Elif", color: .coral, kind: .kind, avatar: "kleiner-astronaut")
        kind.create(.jellyfin(server: server, userID: "u-elif", username: "elif"))
        let store = InMemoryStore()
        ProfileBook(
            profile: [max, kind],
            active: active == "max" ? max.identifier : kind.identifier
        ).write(in: store)
        return (store, max, kind)
    }

    // MARK: - Die Wahl kommt an

    @Test("The chosen figure is in the profile book after saving")
    func choiceArrives() throws {
        let (store, max, _) = Self.ledger(active: "max")
        let pictureState = ProfilePictureState(store: store, cloud: { nil })
        let profile = try #require(pictureState.headerProfile(signedIn: Self.account("u-max")))
        #expect(profile.identifier == max.identifier)

        var choice = ProfilePictureChoice(profile: profile)
        let motif = try #require(AvatarMotif.motif(forItem: "strick-oma"))
        choice.select(motif)
        pictureState.save(choice)

        let read = try #require(
            ProfileBook.read(from: store).profile.first { $0.identifier == max.identifier })
        #expect(read.avatar == "strick-oma")
        // Only the picture — name and color stay.
        #expect(read.name == "Max")
        #expect(read.color == .turquoise)
        // And what the header draws is immediately the new picture.
        #expect(pictureState.headerProfile(signedIn: Self.account("u-max"))?.avatar == "strick-oma")
    }

    /// **"No picture" is `""` and not `nil`** (contract of 2026-09-25): `nil` means "never
    /// decided" and is never written to the cloud — as a delete order it would destroy
    /// there the picture that another device set.
    @Test("\"No picture\" takes back an existing picture, as an empty name")
    func noImageTakesBack() throws {
        let (store, _, kind) = Self.ledger(active: "kind")
        let pictureState = ProfilePictureState(store: store, cloud: { nil })
        var choice = ProfilePictureChoice(profile: kind)
        #expect(choice.avatar == "kleiner-astronaut")
        #expect(!choice.hasNoPictureChosen)

        choice.withoutImage()
        #expect(choice.hasNoPictureChosen)
        pictureState.save(choice)

        let read = ProfileBook.read(from: store).profile.first { $0.identifier == kind.identifier }
        #expect(read?.avatar == "")
        #expect(read?.kind == .kind)
        // The letter is drawn.
        #expect(AvatarMotif.appearance(avatar: read?.avatar, imageExists: { _ in true }) == .letter)
    }

    @Test("A profile without a decision opens the choice on \"No picture\"")
    func neverDecidedShowsNoImage() {
        let (_, max, _) = Self.ledger(active: "max")
        let choice = ProfilePictureChoice(profile: max)
        #expect(max.avatar == nil)
        #expect(choice.hasNoPictureChosen)
    }

    @Test("One's picture does not change the other's")
    func othersStay() {
        let (store, max, kind) = Self.ledger(active: "max")
        let pictureState = ProfilePictureState(store: store, cloud: { nil })
        var choice = ProfilePictureChoice(profile: max)
        choice.select(AvatarMotif.all[0])
        pictureState.save(choice)

        let read = ProfileBook.read(from: store).profile.first { $0.identifier == kind.identifier }
        #expect(read?.avatar == "kleiner-astronaut")
    }

    // MARK: - Wessen Bild wo steht

    @Test("Every account row shows its profile's picture and no other")
    func accountsAreStrict() {
        let (store, max, kind) = Self.ledger(active: "max")
        let pictureState = ProfilePictureState(store: store, cloud: { nil })
        #expect(pictureState.profile(toAccount: Self.account("u-elif"))?.identifier == kind.identifier)
        #expect(pictureState.profile(toAccount: Self.account("u-max"))?.identifier == max.identifier)
        #expect(pictureState.profile(toAccount: Self.account("u-fremd")) == nil)
    }

    @Test("Top right shows the active profile when no account is assigned")
    func headFallsBackToActive() {
        let (store, _, kind) = Self.ledger(active: "kind")
        let pictureState = ProfilePictureState(store: store, cloud: { nil })
        #expect(pictureState.headerProfile(signedIn: nil)?.identifier == kind.identifier)
        #expect(pictureState.headerProfile(signedIn: Self.account("u-fremd"))?.identifier == kind.identifier)
    }

    // MARK: - Fallback to the letter

    @Test(
        "Without a name, empty or unknown: the letter",
        arguments: [nil, "", "gibt-es-nicht", "Strick-Oma"] as [String?])
    func unknownName(name: String?) {
        #expect(AvatarMotif.appearance(avatar: name, imageExists: { _ in true }) == .letter)
    }

    @Test("Known name but no picture in the bundle: the letter")
    func missingFromBundle() {
        #expect(AvatarMotif.appearance(avatar: "strick-oma", imageExists: { _ in false }) == .letter)
    }

    @Test("Known name with picture: the crop of this motif")
    func imageIfPresent() throws {
        let motif = try #require(AvatarMotif.motif(forItem: "popcorn-waschbaer"))
        #expect(
            AvatarMotif.appearance(avatar: "popcorn-waschbaer", imageExists: { _ in true })
                == .image(motif))
    }

    // MARK: - Raster und Titelbild

    @Test("Four columns on the phone, six on the iPad")
    func gridColumns() {
        #expect(MetricClass.profileImageColumns(.compact) == 4)
        #expect(MetricClass.profileImageColumns(nil) == 4)
        #expect(MetricClass.profileImageColumns(.regular) == 6)
    }

    @Test("The title picture's band sits on the face and stays in the picture")
    func bandInImage() {
        // 400 wide, 160 high: face at 35 % → 140 − 80 = 60.
        #expect(ProfileTitleImage.bandTop(midpoint: 0.35, width: 400, height: 160) == 60)
        // At the very top it clamps to the top edge, at the very bottom to the bottom edge.
        #expect(ProfileTitleImage.bandTop(midpoint: 0.05, width: 400, height: 160) == 0)
        #expect(ProfileTitleImage.bandTop(midpoint: 0.95, width: 400, height: 160) == 240)
        // Taller than wide: starts at the top.
        #expect(ProfileTitleImage.bandTop(midpoint: 0.5, width: 100, height: 160) == 0)
    }

    // MARK: - Bundle and catalog

    /// **The image lies in the phone bundle** — otherwise every choice would silently fall back
    /// to the letter, and nobody would notice that the sixteen tiles are empty.
    @Test("Every motif has its picture in the app's asset catalog", arguments: AvatarMotif.all)
    func imageInCatalog(motif: AvatarMotif) {
        #expect(
            (try? SourceText.file(
                "Avatare/\(motif.name).imageset/\(motif.name).png", in: .phoneImages)) != nil)
    }

    /// **The description of each tile is in the catalog, in all three languages.** The
    /// keys come from the shared package and are never written out here —
    /// `strings.py` therefore does not see them, and a missing one would only show up in the
    /// read-aloud voice as `profiles.avatar.…`.
    @Test("Every label is in the string catalog, German, English and Turkish")
    func infoInCatalog() throws {
        let entries = try SourceText.catalogEntries(.phoneCatalog)
        let keys = AvatarMotif.all.map(\.info) + ["profiles.avatarNone"]
        for name in keys {
            let entry = entries[name] as? [String: Any]
            let languages = entry?["localizations"] as? [String: Any]
            #expect(
                Set(languages?.keys.map { $0 } ?? []) == ["de", "en", "tr"],
                "\(name) is missing or not trilingual")
        }
    }
}
