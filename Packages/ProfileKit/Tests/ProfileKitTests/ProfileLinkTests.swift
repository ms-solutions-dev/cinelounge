import Foundation
import Testing

@testable import ProfileKit

/// **On-device test 2026-09-28:** Profiles from the TV to the phone — now as in StoryShelf,
/// with the share link in the QR code itself.
@Suite("Profile link")
struct ProfileLinkTests {

    private let approval = URL(string: "https://www.icloud.com/share/0abcDEF123#Max")!

    @Test("Round trip: link and name are kept")
    func roundTrip() throws {
        let link = ProfileLink(approval: approval, person: "Max", device: "Wohnzimmer")
        let read = try #require(ProfileLink(link.url.absoluteString))
        #expect(read == link)
        #expect(link.url.scheme == ProfileLink.schema)
    }

    @Test("Only iCloud shares — a foreign address is not accepted")
    func iCloudOnly() {
        let foreign = "cinelounge-profil://einrichten?freigabe=https://boese.example/share/x"
        #expect(ProfileLink(foreign) == nil)
        let plainText = "cinelounge-profil://einrichten?freigabe=http://www.icloud.com/share/x"
        #expect(ProfileLink(plainText) == nil)
    }

    @Test("Other codes are not profile links")
    func otherCodes() {
        #expect(ProfileLink("cinelounge://koppeln?code=ABCDEFGHJKMNPQRS&rolle=gebe") == nil)
        #expect(ProfileLink("https://www.icloud.com/share/0abc") == nil)
    }
}
