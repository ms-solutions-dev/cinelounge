import Core
import Foundation

/// What the player **says** about skipping and the next episode — the same wording
/// on both devices (AP58 R4).
///
/// **The keys live in the shared catalog** (`WordingKit`), since the phone has the same
/// buttons. The views look them up through `Text(appKey:)`, which finds the leading
/// catalog; where a number is inserted, this place delivers the finished sentence.
public enum PlaybackWording {

    /// The label of the skip button per section kind. Preview, advertisement and
    /// unknown are called "Intro" — the viewer sees an intro there.
    public static func skip(_ kind: MediaSegment.Kind) -> String {
        switch kind {
        case .outro: "player.skipOutro"
        case .recap: "player.skipRecap"
        case .intro, .preview, .commercial, .unknown: "player.skipIntro"
        }
    }

    /// A sleep timer choice — with the minutes left while it runs (AP85).
    public static func sleep(_ choice: PlaybackCore.SleepChoice, minutesLeft: Int? = nil) -> String {
        switch choice {
        case .off: return AppLanguageSetting.word("player.sleepOff")
        case .endOfEpisode: return AppLanguageSetting.word("player.sleepEndOfEpisode")
        case .minutes(let minutes):
            if let minutesLeft { return AppLanguageSetting.word("player.sleepMinutesLeft \(minutesLeft)") }
            return AppLanguageSetting.word("player.sleepMinutes \(minutes)")
        }
    }

    /// A stable name per choice — for focus and checks.
    public static func sleepIdentifier(_ choice: PlaybackCore.SleepChoice) -> String {
        switch choice {
        case .off: "off"
        case .endOfEpisode: "episode"
        case .minutes(let minutes): "\(minutes)"
        }
    }

    /// The label of the "Back" button after skipping by itself (AP85 binge package): it
    /// says what was skipped, so that "Back" is not a riddle.
    public static func undoSkip(_ kind: MediaSegment.Kind) -> String {
        kind == .recap ? "player.skippedRecapBack" : "player.skippedIntroBack"
    }

    /// The label of the button that dismisses the offer.
    public static let stay = "player.stay"

    /// "Next episode in 7" — a key with a placeholder, because the word order differs
    /// by language.
    public static func nextIn(_ seconds: Int) -> String {
        AppLanguageSetting.word("player.nextIn \(seconds)")
    }

    /// The line above the offer at the end — "Next episode in 7" or **"Similar movie"
    /// without a counter** (AP58 G1, A8): a similar movie never starts by itself, a counter
    /// above it would promise a switch that does not come.
    public static func offer(similar: Bool, seconds: Int) -> String {
        similar ? AppLanguageSetting.word("player.similarOffer") : nextIn(seconds)
    }
}
