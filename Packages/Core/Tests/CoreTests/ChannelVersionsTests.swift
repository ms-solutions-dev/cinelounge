import Foundation
import Testing

@testable import Core

/// Several feeds are one channel.
///
/// **The subject under test is a viewer finding** (2026-08-29: "Varlo–Pendrick shows 10
/// channels"). The names here come from the tested catalog of the provider, including
/// the three identically named entries under the same programme identifier — they are
/// the reason why the name alone does not work as a key.
@Suite("The versions of a channel")
struct ChannelVersionsTests {

    static func channels(
        _ id: String, _ name: String, epg: String? = nil
    ) -> Channel {
        Channel(
            id: id, name: name, streamURL: URL(string: "http://x/\(id)")!, playlistID: "gold",
            epgID: epg)
    }

    /// The measured case: four entries, one station.
    @Test("Four feeds under one programme identifier become one entry")
    func fourBecomeOne() {
        let catalog = [
            Self.channels("1", "KIES: Pusula SP⚽RTS 1 RAW", epg: "PusulaSports1.tr"),
            Self.channels("2", "KIES: Pusula SP⚽RTS 1 RAW", epg: "PusulaSports1.tr"),
            Self.channels("3", "KIES: Pusula SP⚽RTS 1 RAW", epg: "PusulaSports1.tr"),
            Self.channels("4", "KIES: Pusula SP⚽RTS 1 ᵁᴴᴰ 3840P", epg: "PusulaSports1.tr"),
        ]

        let bundles = ChannelVariants.bundles(catalog)

        #expect(bundles.count == 1)
        #expect(bundles[0].count == 4)
        // The 4K variant starts, not the first of the list.
        #expect(bundles[0].best.id == "4")
        // The football symbol stays: it replaces a letter, and ``ChannelName/display(_:)``
        // clears characters only at the edge — otherwise "Pusula SPRTS" would be shown there.
        #expect(bundles[0].name == "KIES: Pusula SP⚽RTS 1")
    }

    /// **Two real channels stay two.** This is the control case to merging: a bundle that
    /// swallows too much takes the row's information away — then a match would be shown
    /// on one channel that is running on two.
    @Test("Two stations stay two entries")
    func twoStayTwo() {
        let catalog = [
            Self.channels("1", "KIES: Pusula SP⚽RTS 1 RAW", epg: "PusulaSports1.tr"),
            Self.channels("2", "KIES: Pusula SP⚽RTS 2 RAW", epg: "PusulaSports2.tr"),
        ]

        #expect(ChannelVariants.bundles(catalog).count == 2)
    }

    /// **The number in the name belongs to the station.** Without this limit, "Pusula
    /// SPORTS 1" and "Pusula SPORTS 2" would become a single "Pusula SPORTS" — and two
    /// channels that show different matches would be one.
    @Test("Numbers are not version words")
    func numbersStay() {
        #expect(
            ChannelVariants.stationName(Self.channels("1", "Pusula SPORTS 1 HD"))
                == "Pusula SPORTS 1")
        #expect(
            ChannelVariants.stationName(Self.channels("2", "SOLA FUSSBALL 2 ᴴᴰ"))
                == "SOLA FUSSBALL 2")
    }

    /// Without a programme identifier — with this provider 58 of 75 entries — the name
    /// carries without a variant word.
    @Test("Without a programme identifier the name bundles")
    func withoutIdentifier() {
        let catalog = [
            Self.channels("1", "DE: SPORTFELD ᴴᴰ"),
            Self.channels("2", "DE: SPORTFELD ᶠᴴᴰ"),
            Self.channels("3", "DE: SPORTFELD MOBIL"),
        ]

        let bundles = ChannelVariants.bundles(catalog)

        #expect(bundles.count == 1)
        #expect(bundles[0].best.id == "2")
        // And the MOBIL variant stands at the back — it was the one that was preselected so
        // far when it happened to be first in the list.
        #expect(bundles[0].variants.last?.id == "3")
    }

    /// **The undescribed variant is not a bad one.** A provider that adds something to
    /// only one of two feeds says nothing about the other — it must neither beat the 4K
    /// variant nor fall behind the MOBIL variant.
    @Test("Without a quality word the middle applies")
    func withoutQualityWord() {
        #expect(ChannelVariants.quality(Self.channels("1", "KIES: Pusula SPORTS 1 RAW")) == 50)
        #expect(
            ChannelVariants.quality(Self.channels("2", "KIES: Pusula SPORTS 1 ᵁᴴᴰ 3840P"))
                > ChannelVariants.quality(Self.channels("1", "KIES: Pusula SPORTS 1 RAW")))
        #expect(
            ChannelVariants.quality(Self.channels("3", "KIES: Pusula SPORTS 1 MOBIL"))
                < ChannelVariants.quality(Self.channels("1", "KIES: Pusula SPORTS 1 RAW")))
    }

    /// The best word in the name wins, not the last: "UHD 3840P" names the same thing
    /// twice, "FHD HEVC" names one and another.
    @Test("Two quality words in the name do not contradict each other")
    func twoQualityWords() {
        #expect(ChannelVariants.quality(Self.channels("1", "X ᵁᴴᴰ 3840P")) == 100)
        #expect(ChannelVariants.quality(Self.channels("2", "X ᶠᴴᴰ HEVC")) == 80)
    }

    /// The order of the bundles is that of the provider — for many the familiar channel
    /// numbering.
    @Test("The order follows first appearance")
    func order() {
        let catalog = [
            Self.channels("1", "B RAW", epg: "b.tr"),
            Self.channels("2", "A RAW", epg: "a.tr"),
            Self.channels("3", "B ᴴᴰ", epg: "b.tr"),
        ]

        #expect(ChannelVariants.bundles(catalog).map(\.name) == ["B", "A"])
    }

    /// A name that consists **only** of a variant word keeps it — otherwise nothing at all
    /// would stand in the row.
    @Test("A name of a single word stays")
    func oneWordStays() {
        #expect(ChannelVariants.stationName(Self.channels("1", "HD")) == "HD")
    }
}
