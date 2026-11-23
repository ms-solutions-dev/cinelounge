import Foundation
import Testing

@testable import Core

/// How audio and subtitle tracks are named.
///
/// That sounds incidental and is not: a selection with "Track 1", "Track 2",
/// "Track 3" is unusable. For a file with German, English and Japanese audio it has
/// to say "German", "English", "Japanese" — otherwise one tries them one by one.
@Suite("Naming tracks")
struct PlaybackTrackTests {

    private let german = Locale(identifier: "de_DE")

    @Test("The language is spelled out in the local language")
    func languageIsLocalized() {
        // The engine delivers ISO codes. Nobody searches for "deu".
        let track = PlaybackTrack(id: 0, rawName: "Track 1", language: "deu")

        #expect(track.displayName(locale: german) == "Deutsch")
    }

    @Test("Without a language the raw name must suffice")
    func fallsBackToRawName() {
        let track = PlaybackTrack(id: 0, rawName: "Kommentar des Regisseurs", language: nil)

        #expect(track.displayName(locale: german) == "Kommentar des Regisseurs")
    }

    @Test("Two tracks of the same language become distinguishable")
    func sameLanguageStaysDistinct() {
        // Happens with movies with an audio commentary. Naming both "German" would be
        // correct and useless.
        let original = PlaybackTrack(id: 0, rawName: "Original", language: "deu")
        let commentary = PlaybackTrack(id: 1, rawName: "Audiokommentar", language: "deu")

        let first = original.displayName(locale: german)
        let second = commentary.displayName(locale: german)

        #expect(first != second)
        #expect(first.contains("Deutsch"))
        #expect(second.contains("Audiokommentar"))
    }

    @Test("A raw name that repeats the language is not shown twice")
    func avoidsRedundancy() {
        // Some files already name the track "German". "German · German" would be silly.
        let track = PlaybackTrack(id: 0, rawName: "Deutsch", language: "deu")

        #expect(track.displayName(locale: german) == "Deutsch")
    }

    @Test("With nothing at all the name stays empty instead of wrong")
    func emptyWhenNothingKnown() {
        // An invented name would be worse: the display can leave out an empty track, but it
        // cannot recognize a wrong name.
        #expect(PlaybackTrack(id: 0).displayName(locale: german).isEmpty)
        #expect(PlaybackTrack(id: 0, rawName: "", language: "").displayName(locale: german).isEmpty)
    }

    @Test("The language is capitalized, even if the system does not do it")
    func capitalized() {
        // On some systems "german" comes back in lowercase. In a list that looks like a bug.
        let track = PlaybackTrack(id: 0, language: "jpn")
        let name = track.displayName(locale: german)

        #expect(name.first?.isUppercase == true, "was “\(name)”")
    }

    @Test("The playback states are distinguishable")
    func statusesAreDistinct() {
        // "Buffering" is not "paused": with one you wait, with the other you have stopped
        // yourself. Whoever displays both the same leaves the viewer in the dark about why
        // the picture is frozen.
        #expect(PlaybackStatus.buffering != PlaybackStatus.paused)
        #expect(PlaybackStatus.ended != PlaybackStatus.idle)
        #expect(
            Set(
                [
                    PlaybackStatus.idle, .opening, .buffering, .playing, .paused, .ended, .failed,
                ].map(\.rawValue)
            ).count == 7)
    }

    @Test("Server tracks become display tracks with Jellyfin numbers")
    func serverTracksBecomeDisplayTracks() {
        // The identifier is the track number of the server — the same one that goes into
        // the address on a switch. The server name is only included where it distinguishes
        // something: "German" suffices as long as there is only one German.
        let tracks = PlaybackTrack.fromServer([
            MediaTrack(id: "5", kind: .audio, title: "German - AC3", language: "deu", codec: "ac3"),
            MediaTrack(id: "7", kind: .audio, title: "English - AC3", language: "eng", codec: "ac3"),
        ])

        #expect(tracks.map(\.id) == [5, 7])
        #expect(tracks[0].language == "deu")
        #expect(tracks[0].rawName == nil, "a single German track needs no server name")

        // Two tracks of the same language: only now does the server name contribute
        // something.
        let doubled = PlaybackTrack.fromServer([
            MediaTrack(id: "1", kind: .audio, title: "Stereo", language: "deu", codec: "aac"),
            MediaTrack(id: "2", kind: .audio, title: "Audiokommentar", language: "deu", codec: "aac"),
        ])
        #expect(doubled.map(\.rawName) == ["Stereo", "Audiokommentar"])

        // Without a language only the name remains — otherwise an empty line would appear.
        let unnamed = PlaybackTrack.fromServer([
            MediaTrack(id: "3", kind: .audio, title: "Ton", codec: "aac")
        ])
        #expect(unnamed[0].rawName == "Ton")

        // A track without a readable number drops out instead of standing there with −1.
        let broken = PlaybackTrack.fromServer([
            MediaTrack(id: "kaputt", kind: .audio, title: "X", codec: "aac")
        ])
        #expect(broken.isEmpty)
    }

    @Test("A forced track is recognizable as such in the menu")
    func forcedTracksAreMarked() {
        // Rebuilt from "Realm of the Herons — Ausbruch": a German forced track and an
        // English full track. Each is the only one of its language — before 2026-08-28 they
        // were called simply "German" and "English" in the menu, and the viewer chose
        // "German" and got 199 captions instead of the 800 of the whole film.
        let tracks = PlaybackTrack.fromServer([
            MediaTrack(
                id: "3", kind: .subtitle, title: "Forced - German - Erzwungen - SUBRIP",
                language: "deu", codec: "subrip", subtitleFormat: .subrip, isDefault: true,
                isForced: true),
            MediaTrack(
                id: "4", kind: .subtitle, title: "English - SUBRIP", language: "eng",
                codec: "subrip", subtitleFormat: .subrip),
        ])

        #expect(tracks[0].isForced)
        #expect(!tracks[1].isForced)

        let germanTrack = tracks[0].displayName(locale: german)
        #expect(germanTrack.hasPrefix("Deutsch"))
        #expect(germanTrack != "Deutsch", "the forced property must be visible")
        // **As a word, not as a key** (AP58 R0): the word comes from the shared `WordingKit`
        // catalog that every program brings along — this check run too. Via the app's
        // catalog this used to say "Deutsch · player.subtitleForced" as soon as the app did
        // not carry the key.
        #expect(!germanTrack.contains("player.subtitleForced"))
        #expect(tracks[1].displayName(locale: german) == "Englisch")
    }

    @Test("Two German tracks differ by the suffix, not by the server name")
    func forcedReplacesTheServerName() {
        // "Aufbruch": two German SubRip tracks, one forced. The server name
        // ("de--forced-- - German - Standard - Erzwungen - SUBRIP") contributes nothing
        // here once the suffix makes the difference — and on a remote it is a line to skim
        // over.
        let tracks = PlaybackTrack.fromServer([
            MediaTrack(
                id: "3", kind: .subtitle,
                title: "de--forced-- - German - Standard - Erzwungen - SUBRIP", language: "deu",
                codec: "subrip", subtitleFormat: .subrip, isDefault: true, isForced: true),
            MediaTrack(
                id: "4", kind: .subtitle, title: "Deutsch - German - SUBRIP", language: "deu",
                codec: "subrip", subtitleFormat: .subrip),
        ])

        #expect(tracks.map(\.rawName) == [nil, nil], "the suffix suffices as a distinction")
        #expect(tracks[1].displayName(locale: german) == "Deutsch")

        // Two forced tracks of the same language: now the server name contributes something
        // again, because the suffix then stands on both.
        let both = PlaybackTrack.fromServer([
            MediaTrack(
                id: "0", kind: .subtitle, title: "SDH", language: "deu", codec: "subrip",
                subtitleFormat: .subrip, isForced: true),
            MediaTrack(
                id: "1", kind: .subtitle, title: "Standard", language: "deu", codec: "subrip",
                subtitleFormat: .subrip, isForced: true),
        ])
        #expect(both.map(\.rawName) == ["SDH", "Standard"])
    }
}
