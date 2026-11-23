import Foundation

/// What the phone tells the TV.
///
/// **A set of commands and not a remote control of the pointer.** The obvious design
/// would have been to replicate the keys of the Siri Remote — up, down, select.
/// That would be a second remote for a device that already has one, and a worse one: A swipe
/// field on glass hits less accurately than a trackpad operated blindly. **What the phone does
/// better is everything the Siri Remote has no key for** — tapping a spot in the film, typing
/// a title, choosing an audio track.
///
/// **The agreement on the wire is the case names, not numbers** (corrected on
/// 2026-09-27, ultra e5, round A.7). `Command` uses the derived `Codable` encoding:
/// `.jumpBy(-10)` goes across as `{"jumpBy":{"_0":-10}}`, `.spieleTitel` with
/// its labels `identifier`, `origin`, `from`. **Whoever renames a case or a
/// label breaks every phone and every TV of an older version** —
/// a changed order, on the other hand, does no harm. Until then this said the opposite:
/// that the numbers from ``code`` were the agreement. They never appeared on the wire.
/// The check `RemoteTests.wireFormat` pins the format down.
///
/// **Unknown commands are rejected, not guessed.** A TV that does not know a command
/// acknowledges it — it does not do the closest thing.
///
/// ## Why there is no volume command
///
/// **The schedule provided a `VolumeSlider`, and tvOS cannot honor it.** Checked on
/// 2026-09-10: There is **no** interface there with which an app sets the system volume —
/// `MPVolumeView` does not exist on tvOS, and `AVAudioSession` has no setter there. The
/// volume of an Apple TV belongs to the TV or the amplifier on the HDMI cable and is set
/// via CEC, not by the app.
///
/// **A slider that moves nothing is worse than none:** It looks like a control, and whoever
/// drags it then looks for the fault in themselves. The volume therefore stays with the TV's
/// remote — where it lies anyway.
public enum Command: Sendable, Equatable, Codable {
    /// Stored case names keep their original (German) form — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case matches = "spiele"
        case jumpTo = "springeAuf"
        case jumpBy = "springeUm"
        case audioTrack = "tonspur"
        case subtitles = "untertitel"
        case spieleTitel
        case tap = "tippe"
        case halt
    }

    /// Stored keys of ``spieleTitel`` keep their original (German) names (AP85 B4).
    private enum SpieleTitelCodingKeys: String, CodingKey {
        case identifier = "kennung"
        case origin = "herkunft"
        case from = "ab"
    }

    /// Pause or resume — **a command and not a toggle.**
    ///
    /// The phone knows from the ``StateMirror`` what currently applies; a "toggle"
    /// would, with a lost packet, do the opposite of what the thumb wanted.
    case matches(Bool)

    /// Jump to this position, in seconds from the start.
    case jumpTo(TimeInterval)

    /// Jump by this span — negative goes back.
    ///
    /// **Both and not just one.** "To 42:10" is the timeline, "by −10" is the
    /// double tap; calculating the position from the span would mean calculating it on the
    /// phone — and there the TV's state is always half a second old.
    case jumpBy(TimeInterval)

    /// Choose an audio track.
    case audioTrack(Int)

    /// Choose a subtitle track — `nil` turns it off.
    case subtitles(Int?)

    /// Open a title and play it.
    ///
    /// **The identifier travels with the origin.** The same string means different things for a
    /// portal and for the media server; without the origin the TV would have to guess, and
    /// guessing was the mistake the detail page of this project has already made twice.
    /// **And from which position** — otherwise "continue watching on the TV" would be a
    /// "start over on the TV". That difference is exactly the purpose.
    case spieleTitel(identifier: String, origin: String, from: TimeInterval)

    /// Write text into the field that is currently open on the TV.
    case tap(String)

    /// End playback.
    case halt

    /// A fixed number per case — **an ordinal, not the network format.**
    ///
    /// Until 2026-09-27 this said that the case goes over the wire "by hand and not through the
    /// derived encoding", as this number. That was never true: Encoding
    /// is by **case name** (see above), and nobody reads this number except the
    /// checks. Switching the encoding to the number now would break every paired
    /// device of an older version — for a protection against renaming that the
    /// wire-format check provides more cheaply. The number stays, so that a
    /// later format of its own does not have to renumber.
    public var code: UInt8 {
        switch self {
        case .matches: 0
        case .jumpTo: 1
        case .jumpBy: 2
        case .audioTrack: 3
        case .subtitles: 4
        case .spieleTitel: 5
        case .tap: 6
        case .halt: 7
        }
    }
}

/// **A typed password ends up in no log** (counter-check strand D, finding 1.7).
///
/// ``Command/tap(_:)`` carries what arrives in the field on the TV — in the password field
/// the password. The derived description would write it out in plain text on every `print`,
/// `dump` or `Logger` call with `\(command)`. That is why only the length appears there.
extension Command: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {

    public var description: String {
        switch self {
        case .matches(let on): "spiele(\(on))"
        case .jumpTo(let location): "springeAuf(\(location))"
        case .jumpBy(let span): "springeUm(\(span))"
        case .audioTrack(let track): "tonspur(\(track))"
        case .subtitles(let track): "untertitel(\(track.map(String.init) ?? "aus"))"
        case .spieleTitel(let identifier, let origin, let from):
            "spieleTitel(\(identifier), \(origin), from: \(from))"
        case .tap(let text): "tippe(••• \(text.count) characters)"
        case .halt: "halt"
        }
    }

    public var debugDescription: String { "Befehl.\(description)" }

    public var customMirror: Mirror {
        Mirror(self, children: ["befehl": description], displayStyle: .enum)
    }
}
