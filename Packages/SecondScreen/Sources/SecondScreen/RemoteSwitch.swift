import Foundation

/// Where a command from the phone goes — **before asking whether a player is running.**
///
/// **The seam where the remote keyboard hung** (setup check, E9, 2026-09-27). The
/// remote control on the TV discarded every command except "open title" as long as no
/// player was running — `.tap` too. But the remote keyboard is built exactly for the screens without a
/// player: sign-in, settings, search. The phone showed "field open", and
/// what was typed never arrived.
///
/// **Here and not in `Features`**, because the remote control there is only
/// compiled on the TV; the decision which command needs a player is not a question
/// of the platform and should be testable without a TV.
@MainActor
public enum RemoteSwitch {

    public enum Target: Equatable, Sendable {
        /// The command belongs to the running player.
        case player
        /// A title is to be opened — the shell knows how.
        case title(identifier: String, origin: String, from: TimeInterval)
        /// Already handled, without a player (the remote keyboard).
        case done
        /// Ohne Spieler nichts zu tun.
        case discarded
    }

    /// Routes a command — **the remote keyboard handles it itself.**
    public static func derive(_ command: Command, playerPresent: Bool) -> Target {
        switch command {
        case .spieleTitel(let identifier, let origin, let from):
            return .title(identifier: identifier, origin: origin, from: from)
        case .tap(let text):
            RemoteKeyboard.give(text)
            return .done
        default:
            return playerPresent ? .player : .discarded
        }
    }
}
