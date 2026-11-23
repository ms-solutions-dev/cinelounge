import Foundation

/// What is currently playing on the TV.
///
/// **Without this mirror the remote would be flying blind.** The prototype really counts on
/// it: 2653 of 8297 seconds, and −10 as well as +30 move the track **and** both time
/// readouts. A remote that only sends leaves the thumb guessing whether something has
/// arrived — and on a network that needs half a second, it guesses wrong.
///
/// **The TV sends, the phone does not ask.** A phone that asks on a beat poses seven
/// thousand questions during a two-hour film for seven answers that differ. The TV knows
/// every change anyway at the moment it happens.
///
/// **No volume.** An app on tvOS cannot set it (see ``Command``), and a number that is
/// shown and cannot be changed is, on the phone, a control that is none.
///
/// **It carries the position and not the time of day.** Whoever sent a time of day would
/// require the phone to calculate it against its own — and the two clocks of two devices
/// run differently. The position is the position.
public struct StateMirror: Sendable, Equatable, Codable {

    /// Whether anything is playing at all. With `nil` the TV is on a list, not in a film — and
    /// then the rest carries nothing.
    public var title: String?

    /// The second line — season and episode, or the channel.
    public var beside: String?

    /// **The ID of the title being played — the key to "bring it here".**
    ///
    /// Without it the mirror is a display and not a handoff: a title as **text** cannot be
    /// opened. "Bloufeit" exists three times — on the media server, in the provider catalog and in
    /// a portal —, and which of them is playing is told by the ID alone.
    ///
    /// **The origin does not travel along, and that is no omission.** It is in the ID:
    /// `PlaybackJob.origin(zu:)` reads it off the format — a portal key looks different from
    /// a provider ID, and that again different from one of the media server. Sending it
    /// **in addition** would mean keeping the same information twice; if the two drift apart,
    /// the wrong one wins.
    ///
    /// `nil` for a channel: there is nothing to bring there — one would arrive at the same
    /// place one is at anyway.
    public var identifier: String?

    /// Where in the film. Seconds from the start.
    public var location: TimeInterval

    /// How long the film is. `nil` for a channel: there is no end there.
    public var duration: TimeInterval?

    /// Whether playback is running right now — `false` means paused, not ended.
    public var isRunning: Bool

    /// Whether a text input field is currently open on the TV.
    ///
    /// **This decides whether the keyboard sheet opens on the phone.** A keyboard that can be
    /// opened while there is no field over there types into the void — and one only notices
    /// when one has finished typing.
    public var keyboardOpen: Bool

    /// What is already in this field — **so that the phone can mirror it.**
    ///
    /// The point of the keyboard sheet is that one does **not** look back and forth between two
    /// screens. For that, the phone has to show what is over there.
    public var keyboardText: String

    /// Whether the open field is a **password field** (AP39, 2026-09-25).
    ///
    /// Then ``keyboardText`` stays empty — **always, also over the paired wire.** The phone
    /// shows a masked field and types blind; the password goes in one direction only. A mirror
    /// that sent it back would put it on every connected phone.
    public var keyboardSecret: Bool

    public init(
        title: String? = nil, beside: String? = nil, identifier: String? = nil,
        location: TimeInterval = 0,
        duration: TimeInterval? = nil, isRunning: Bool = false,
        keyboardOpen: Bool = false, keyboardText: String = "", keyboardSecret: Bool = false
    ) {
        self.title = title
        self.beside = beside
        self.identifier = identifier
        self.location = location
        self.duration = duration
        self.isRunning = isRunning
        self.keyboardOpen = keyboardOpen
        self.keyboardText = keyboardText
        self.keyboardSecret = keyboardSecret
    }

    enum CodingKeys: String, CodingKey {
        case title = "titel", beside = "neben", identifier = "kennung", location = "stelle", duration =
            "dauer", isRunning = "laeuft", keyboardOpen = "tastaturOffen", keyboardText = "tastaturtext"
        case keyboardSecret = "tastaturGeheim"
    }

    /// **`keyboardSecret` may be missing** — a TV of an older version does not send it, and the
    /// mirror must not fail because of that.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        beside = try values.decodeIfPresent(String.self, forKey: .beside)
        identifier = try values.decodeIfPresent(String.self, forKey: .identifier)
        location = try values.decode(TimeInterval.self, forKey: .location)
        duration = try values.decodeIfPresent(TimeInterval.self, forKey: .duration)
        isRunning = try values.decode(Bool.self, forKey: .isRunning)
        keyboardOpen = try values.decode(Bool.self, forKey: .keyboardOpen)
        keyboardText = try values.decode(String.self, forKey: .keyboardText)
        keyboardSecret = try values.decodeIfPresent(Bool.self, forKey: .keyboardSecret) ?? false
    }

    /// The same state with what the ``RemoteKeyboard`` currently knows — **the one way by which
    /// the field gets into the mirror.** For a password field the text stays empty.
    @MainActor
    public func withRemoteKeyboard() -> StateMirror {
        var fresh = self
        fresh.keyboardOpen = RemoteKeyboard.pending
        fresh.keyboardSecret = RemoteKeyboard.isSecret
        fresh.keyboardText = RemoteKeyboard.isSecret ? "" : RemoteKeyboard.text
        return fresh
    }

    /// Nothing is playing — the state of a TV that is on a list.
    public static let idle = StateMirror()

    /// Whether a picture is playing that can be remote-controlled.
    public var isPlaying: Bool { title != nil }

    /// Whether this title can be brought to the phone.
    ///
    /// **A channel cannot be brought**, and that is no restriction: it runs equally far
    /// everywhere, one would arrive at the same place. What "bring it here" means is "continue
    /// watching at *my* position" — and that exists only where there is a position.
    public var fetchable: Bool { identifier != nil && duration != nil }

    /// How far along the film is, 0 to 1 — `nil` where there is no end.
    ///
    /// **Calculated and not sent along.** Two numbers that say the same thing drift apart as
    /// soon as one of them is rounded.
    public var progress: Double? {
        guard let duration, duration > 0 else { return nil }
        return min(1, max(0, location / duration))
    }
}
