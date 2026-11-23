import Core
import Foundation
import Testing

@testable import ParentalControls

/// Moving a PIN to another device.
///
/// **The place where a mistake would only be noticed at the child.** If the salt does not travel along,
/// the TV checks against a different digest and rejects the **correct** PIN —
/// or, worse, the parental control stands there switched on without any
/// input opening it. Neither can be seen from any screen.
@Suite("The PIN moves")
struct PinExtractTests {

    @Test("Without an assigned PIN there is nothing to take along")
    func withoutPinNoExtract() {
        let pin = Pin(store: InMemoryStore())

        #expect(pin.extract == nil)
    }

    @Test("The same PIN also opens on the other device")
    func pinAlsoValidOnOtherSide() throws {
        let phone = Pin(store: InMemoryStore())
        #expect(phone.set("4711"))

        let extract = try #require(phone.extract)
        let tv = Pin(store: InMemoryStore())
        tv.adopt(extract)

        #expect(tv.isSet)
        #expect(tv.matches("4711"))
        #expect(!tv.matches("1234"), "a wrong one stays wrong")
    }

    @Test("Without the salt the other device checks against nothing")
    func withoutSaltNothingOpens() throws {
        // **Why the salt is in the export at all.** It is random per device; if only
        // the digest were taken along, the two devices would compare two hashes of the same digits
        // with different salt — and those never match.
        let phone = Pin(store: InMemoryStore())
        #expect(phone.set("4711"))
        let extract = try #require(phone.extract)

        let tv = Pin(store: InMemoryStore())
        tv.adopt(
            Pin.Extract(digest: extract.digest, salt: "ein anderes Salz", changed: nil))

        #expect(tv.isSet, "there is something there …")
        #expect(!tv.matches("4711"), "… and the right PIN still does not open")
    }

    @Test("The change date moves along")
    func dateTravelsAlong() throws {
        let phone = Pin(store: InMemoryStore())
        #expect(phone.set("0000"))
        let extract = try #require(phone.extract)

        let tv = Pin(store: InMemoryStore())
        tv.adopt(extract)

        // Without the date the line in the sheet said "never changed" although it had been.
        let otherSide = try #require(tv.changed)
        let here = try #require(phone.changed)
        #expect(abs(otherSide.timeIntervalSince(here)) < 1)
    }
}
