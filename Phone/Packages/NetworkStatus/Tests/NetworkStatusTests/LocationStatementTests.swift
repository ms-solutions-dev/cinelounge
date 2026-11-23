import Testing

@testable import NetworkStatus

@Suite("Location statement")
struct LocationStatementTests {

    /// The rule at issue: **never a shared sentence for all sources.** Exactly one of the three
    /// hangs on the tunnel, and a message "slow connection" would be simply wrong for two of
    /// three.
    @Test("No sentence stands in two places")
    func eachLocationOwnSentence() {
        var seen: [String: LocationStatement.Place] = [:]
        for place in LocationStatement.Place.allCases {
            for location in [LocationStatement.Location.home, .inFlight] {
                for source in LocationStatement.Source.allCases {
                    // **`home` and `inFlight` are the two cases that have a sentence.** Since 2026-09-10.
                    // `unknown` returns nothing — that is why there is a `guard` here and not a `!`: A
                    // check that crashes on an intended gap reports the wrong error.
                    guard
                        let key = LocationStatement.forItem(
                            place, location: location, source: source)?.key
                    else {
                        Issue.record("\(place) at \(location) has no sentence")
                        continue
                    }
                    if let existing = seen[key] {
                        #expect(existing == place, "\(key) stands at \(existing) and at \(place)")
                    }
                    seen[key] = place
                }
            }
        }
    }

    @Test("Every situation has a sentence", arguments: LocationStatement.Place.allCases)
    func noGap(place: LocationStatement.Place) {
        for location in [LocationStatement.Location.home, .inFlight] {
            #expect(LocationStatement.forItem(place, location: location)?.key.isEmpty == false)
        }
    }

    /// Only two places are really different on the go — and only those two are framed. A
    /// warning on every line would no longer be a warning.
    @Test("A warning appears twice, not everywhere")
    func warnings() {
        var warnings = 0
        for place in LocationStatement.Place.allCases {
            for location in [LocationStatement.Location.home, .inFlight] {
                for source in LocationStatement.Source.allCases {
                    if LocationStatement.forItem(place, location: location, source: source)?.warning == true {
                        warnings += 1
                    }
                }
            }
        }
        // Jellyfin on the go in the library, and "Automatic" in the sources sheet.
        // The sources sheet counts three times because the source changes nothing there.
        #expect(warnings == 4)
        #expect(LocationStatement.forItem(.library, location: .inFlight, source: .jellyfin)?.warning == true)
        #expect(LocationStatement.forItem(.library, location: .inFlight, source: .xtream)?.warning == false)
        #expect(LocationStatement.forItem(.sourceSheet, location: .inFlight)?.warning == true)
        #expect(LocationStatement.forItem(.sourceSheet, location: .home)?.warning == false)
    }

    /// The occupied TV changes the sentence — it is not an addition appended, but a different
    /// sentence. Two composed texts could not be translated in three languages.
    @Test("The occupied TV has a sentence of its own")
    func taken() {
        let unrestricted = LocationStatement.forItem(.live, location: .home, tvOccupied: false)
        let taken = LocationStatement.forItem(.live, location: .home, tvOccupied: true)
        #expect(unrestricted?.key != taken?.key)
    }

    /// A child account may not see two of the three catalogs at all. A line that lists them
    /// would be exactly the contradiction that the search below avoids.
    @Test("The child account gets its own sentence")
    func childAccount() {
        let kind = LocationStatement.forItem(.search, location: .home, childAccount: true)
        #expect(kind?.key == "place.search.child")
        #expect(
            LocationStatement.forItem(.search, location: .inFlight, childAccount: true)?.key
                == kind?.key)
    }
}
