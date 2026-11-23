import Foundation
import Testing

@testable import PortalKit

/// What becomes of a pasted invitation.
///
/// **The finding that triggered this file (2026-09-12):** the client typed the console's invitation link
/// into the field for the server address — because there was no field for an invitation. The answer was
/// "The bridge does not answer": correct and completely unusable.
@Suite("A pasted invitation")
struct InvitationTests {

    /// The link as the server itself generates it.
    @Test("A link carries password and address")
    func linkWithAddress() throws {
        let read = try #require(
            Invitation(input: "http://192.0.2.183:8100/?invite=khfsxz4y4fhrybtx6tutx2"))
        #expect(read.password == "khfsxz4y4fhrybtx6tutx2")
        #expect(read.bridgeAddress?.absoluteString == "http://192.0.2.183:8100")
        #expect(read.isPairingCode == false)
    }

    /// **The core:** the console's host name is the browser's address and not the devices'.
    ///
    /// The certificate is from mkcert, and its root is in the home's browser and not in every device. An app
    /// that took the address from here would fail on the certificate chain — the password is usable anyway.
    @Test("From cl.example no address results, but a password does")
    func clHomeGivesNoAddress() throws {
        let read = try #require(
            Invitation(input: "https://cl.example/?invite=wcqdhd53t6cz79j8mebthz"))
        #expect(read.password == "wcqdhd53t6cz79j8mebthz")
        #expect(read.bridgeAddress == nil)
    }

    /// Without a number the link does not say where the service listens for devices — and guessing 8100 would
    /// be the same claim that has just been abolished as a default.
    @Test("Without a port no address")
    func withoutNumber() throws {
        let read = try #require(Invitation(input: "http://cl.example/?invite=abcdefghijkl"))
        #expect(read.password == "abcdefghijkl")
        #expect(read.bridgeAddress == nil)
    }

    @Test("A bare password works too")
    func bareToken() throws {
        let invitation = try #require(Invitation(input: "wcqdhd53t6cz79j8mebthz"))
        #expect(invitation.password == "wcqdhd53t6cz79j8mebthz")
        #expect(invitation.bridgeAddress == nil)
        #expect(invitation.isPairingCode == false)

        let pairing = try #require(Invitation(input: " G29BYV "))
        #expect(pairing.password == "G29BYV")
        #expect(pairing.isPairingCode)
    }

    /// **Nothing is reshaped.** The server accepts both spellings; lowercasing here would mean making an
    /// assumption about its leniency.
    @Test("The spelling stays as it comes")
    func spellingStays() throws {
        #expect(try #require(Invitation(input: "g29byv")).password == "g29byv")
        #expect(try #require(Invitation(input: "G29BYV")).password == "G29BYV")
    }

    @Test("What is not an invitation does not become one")
    func isUnusable() {
        #expect(Invitation(input: "") == nil)
        #expect(Invitation(input: "   ") == nil)
        // Too short for either.
        #expect(Invitation(input: "abc") == nil)
        // An address without an invitation is an address.
        #expect(Invitation(input: "192.0.2.183:8100") == nil)
        // A pasted sentence is no password; sending it would produce a refusal that explains nothing.
        #expect(Invitation(input: "hier ist dein Zugang") == nil)
        #expect(Invitation(input: "http://192.0.2.183:8100/?invite=") == nil)
    }
}
