import Testing

@testable import FeaturesPhone

/// Whether a hostname means a different **audio version**.
///
/// **The finding (E61):** For the Ahorn the "hosts" are resolution tiers. The automatic
/// fallback takes the next entry — and the next one can be the audio-described version
/// for the blind. One resolution tier lower is the same picture in worse quality; an
/// audio description is a **different film**.
@Suite("Audio versions in the host name")
struct AudioVersionTests {

    @Test("The words used by the media libraries are recognised")
    func recognizedWord() {
        #expect(AudioVersion.isSecondaryVersion("HD 1080p · Audiodeskription"))
        #expect(AudioVersion.isSecondaryVersion("Das Nordlicht (Hörfassung)"))
        #expect(AudioVersion.isSecondaryVersion("Nachrichten in Klare Sprache"))
    }

    /// **Upper and lower case must not decide.** The bridge passes through what
    /// the portal delivers, and each one writes it differently.
    @Test("The spelling does not matter")
    func spellingIrrelevant() {
        #expect(AudioVersion.isSecondaryVersion("AUDIODESKRIPTION"))
        #expect(AudioVersion.isSecondaryVersion("hörfassung"))
        #expect(AudioVersion.isSecondaryVersion("HoerFassung"))
    }

    /// **The case that must not go wrong.** Whoever recognizes too much here takes the
    /// fallback its hosts — and a download that cannot fall back is a
    /// download that fails.
    @Test("Ordinary hosts and tiers are left alone")
    func ordinaryOnesStay() {
        for name in [
            "HD 1080p", "Web M", "HOSTA", "Hostd", "Hosth",
            "SD 480p", "Das Nordlicht", "Original", "Deutsch",
        ] {
            #expect(
                !AudioVersion.isSecondaryVersion(name), "\u{201C}\(name)\u{201D} is not a secondary version")
        }
    }

    /// The boundary is included as a check: An English portal fails it, and that is
    /// written down instead of claimed.
    @Test("What the list does not know, it does not recognise")
    func listLimit() {
        #expect(!AudioVersion.isSecondaryVersion("descriptive audio"))
        #expect(!AudioVersion.isSecondaryVersion("audio description"))
    }
}
