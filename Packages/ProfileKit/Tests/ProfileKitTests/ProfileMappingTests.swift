import CloudSync
import Core
import Foundation
import Testing

@testable import ProfileKit

/// A profile as records and back — without zone, without account, without a network.
@Suite("Profile as records")
struct ProfileMappingTests {

    let server = URL(string: "https://jellyfin.example:8096")!

    func sample(name: String = "Max") -> Profile {
        var profile = Profile(
            identifier: Profile.Identifier(rawValue: UUID().uuidString), name: name, color: .turquoise,
            kind: .adult)
        profile.create(.jellyfin(server: server, userID: "u1", username: "max"))
        profile.create(.channelList(identifier: "xtream|panel.example|max"))
        profile.create(.channelList(identifier: "m3u|listen.example|sina"))
        profile.create(.portals(person: "max"))
        return profile
    }

    @Test("Round trip loses nothing")
    func roundTrip() {
        let profile = sample()
        let wordings = ProfileMapping.wordings(forItem: profile)
        let back = ProfileMapping.profile(identifier: profile.identifier, from: wordings)
        #expect(back == profile)
    }

    /// **The order is information and not chance** — which access
    /// someone started with (``ProfileKit/credentials``). Records come back sorted by name;
    /// without the field `order`, after the first sync an alphabetical list
    /// would stand there, and nobody would have noticed.
    @Test("The order of the credentials survives the trip through the zone")
    func order() {
        let profile = sample()
        // Alphabetically it would be the reverse order: jellyfin, portale, senderliste|m3u…,
        // senderliste|xtream… — the example order is deliberately a different one.
        let wordings = ProfileMapping.wordings(forItem: profile).shuffled()
        #expect(ProfileMapping.credentials(from: wordings) == profile.credentials)
    }

    /// That this mapping uses the same names as ``CloudSync/CloudHub``.
    ///
    /// **They are spelled out here and not taken over**, because the hub's constants
    /// are `@MainActor`-bound. So that "spelled out" does not become
    /// "drifted apart", this check lives here: If `CloudSync` renames one of the
    /// four, it turns red — and not only the sync on the device, where a profile
    /// without a name is an empty circle in the switcher.
    @Test("The same names as in the central definition")
    @MainActor
    func nameEquality() {
        #expect(ProfileMapping.settingType == CloudHub.settingType)
        #expect(ProfileMapping.nameKey == CloudHub.nameKey)
        #expect(ProfileMapping.colorKey == CloudHub.colorKey)
        #expect(ProfileMapping.valueField == CloudHub.valueField)
    }

    /// **The zone hangs on the ID and not on the name.** Whoever renames their profile
    /// keeps their state — that is the reasoning already at ``ProfileKit/Identifier``,
    /// and here it is checked.
    @Test("Renaming leaves the zone alone")
    func rename() {
        var profile = sample()
        let previous = ProfileMapping.zone(forItem: profile.identifier)
        profile.name = "Papa"
        #expect(ProfileMapping.zone(forItem: profile.identifier) == previous)
        #expect(previous?.isProfile == true)
    }

    /// An ID that is not a UUID gets **no** zone.
    ///
    /// ``ProfileKit/Identifier/fresh()`` always creates one, but the build path is public. A
    /// zone with a different name pattern could not be found again on the second device,
    /// and that would only be noticed when the state does not arrive.
    @Test("No UUID, no zone")
    func noZone() {
        #expect(ProfileMapping.zone(forItem: Profile.Identifier(rawValue: "max")) == nil)
        #expect(ProfileMapping.zone(forItem: Profile.Identifier(rawValue: "")) == nil)
    }

    @Test("No name, no profile")
    func withoutName() {
        let profile = sample()
        let without = ProfileMapping.wordings(forItem: profile)
            .filter { !($0.contentType == ProfileMapping.settingType && $0.name == "name") }
        #expect(ProfileMapping.profile(identifier: profile.identifier, from: without) == nil)

        let empty = ProfileMapping.wordings(forItem: Profile(identifier: profile.identifier, name: ""))
        #expect(ProfileMapping.profile(identifier: profile.identifier, from: empty) == nil)
    }

    /// Color and type are taste, not substance — they fall back instead of dropping the
    /// whole profile.
    @Test("Color and kind fall back to the default")
    func parameters() {
        let identifier = Profile.Identifier.fresh()
        let nameOnly = [
            CloudRecord(
                contentType: ProfileMapping.settingType, name: "name", fields: ["wert": .text("Selin")])
        ]
        let profile = ProfileMapping.profile(identifier: identifier, from: nameOnly)
        #expect(profile?.name == "Selin")
        #expect(profile?.color == .amber)
        #expect(profile?.kind == .adult)
    }

    /// **What the type does not know is not guessed.** Such a record comes from
    /// a newer version of this app; a half-read media-server access
    /// would be worse than none.
    @Test("A credential of unknown kind is dropped, the rest stays")
    func unknownKind() {
        let profile = sample()
        var wordings = ProfileMapping.wordings(forItem: profile)
        wordings.append(
            CloudRecord(
                contentType: ProfileMapping.accessType, name: "webdav|irgendwo",
                fields: ["art": .text("webdav"), "reihenfolge": .integer(0)]))
        #expect(ProfileMapping.credentials(from: wordings) == profile.credentials)
    }

    /// **An empty person field is an answer.** "Portals without a person" is the case
    /// of the bare bridge: Every device on the network sees everything (see
    /// ``Access/portals(person:)``). Whoever turns that into an absence loses the wish.
    @Test("Portals without a person stay portals")
    func portalsWithoutPerson() {
        var profile = Profile(identifier: .fresh(), name: "Wohnzimmer")
        profile.create(.portals(person: nil))
        let back = ProfileMapping.profile(
            identifier: profile.identifier, from: ProfileMapping.wordings(forItem: profile))
        #expect(back?.credentials == [.portals(person: nil)])
        #expect(back?.wantsPortals == true)
    }

    /// **The same access has the same name on two devices.** Otherwise there would be duplicates instead of
    /// conflicts: Two devices that store the same access under two names never
    /// fight with each other — they both stand there.
    @Test("A credential's record name depends only on the credential")
    func recordName() {
        let list = Access.channelList(identifier: "xtream|panel.example|max")
        #expect(
            ProfileMapping.recordName(forItem: list)
                == "senderliste|xtream|panel.example|max")
        #expect(
            ProfileMapping.recordName(
                forItem: .jellyfin(server: server, userID: "u1", username: "max"))
                == ProfileMapping.recordName(
                    forItem: .jellyfin(server: server, userID: "u1", username: "Max I."))
        )
    }

    /// The name alone — for the zone search, which does not want to build a profile yet.
    @Test("The name can be read without the whole profile")
    func onlyTheName() {
        let wordings = ProfileMapping.wordings(forItem: sample(name: "Sina"))
        #expect(ProfileMapping.name(from: wordings) == "Sina")
        #expect(ProfileMapping.name(from: []) == nil)
    }
}
