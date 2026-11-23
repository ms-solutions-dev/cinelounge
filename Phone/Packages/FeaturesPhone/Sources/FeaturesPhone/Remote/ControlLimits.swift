import Foundation
import SecondScreen

/// What does **not** work from here — and why.
///
/// **A remote that offers everything promises more than the TV holds.** The
/// three sources of this app cannot do the same, and the difference is no subtlety:
/// whoever drags the timeline on a channel drags at nothing.
///
/// **The rule lives here and not in the view.** It has four cases and is needed in three
/// places — timeline, skip buttons, keyboard button. The same condition three times
/// in the body would be three opportunities to forget one.
public enum ControlLimits {

    /// Whether seeking is possible at this position.
    ///
    /// **By the duration and not by the origin.** A channel has no end and therefore
    /// reports no duration; a remuxer stream likewise. The question "is there an end" is
    /// the same as "can you jump there", and it answers itself from the state —
    /// without the remote having to know which of the three sources is currently running.
    public static func canSeek(_ mirror: StateMirror) -> Bool {
        guard let duration = mirror.duration else { return false }
        return duration > 0
    }

    /// Whether the keyboard sheet can accomplish anything.
    ///
    /// **Only if a field is really open over there.** A keyboard you can open
    /// while no field stands on the TV types into nothing — and you notice it
    /// only when you have finished typing. The button is then **gone** and not
    /// dimmed: the same rule as at ``CommandButtons``, a dimmed button is
    /// an invitation that is not honoured.
    public static func canTap(_ mirror: StateMirror) -> Bool {
        mirror.keyboardOpen
    }

    /// Whether there is anything to operate at all.
    public static func canControl(_ mirror: StateMirror) -> Bool {
        mirror.isPlaying
    }

    /// **There is no volume slider, and that is a measurement and not a gap.**
    ///
    /// The roadmap planned one. Checked on 2026-09-10: **tvOS has no
    /// interface with which an app sets the system volume** — `MPVolumeView`
    /// does not exist there, `AVAudioSession` knows no setter. The volume of an
    /// Apple TV belongs to the TV or the amplifier on the HDMI cable and is set via CEC,
    /// not by the app.
    ///
    /// **A slider that moves nothing is worse than none:** it looks like a
    /// control, and whoever drags it then looks for the fault in themselves. It therefore stands
    /// neither here nor in the wire — the volume stays with the remote of the
    /// TV, where it lies anyway.
    ///
    /// *This line is the place where that is written down.* Without it someone will ask in the next
    /// pass why the remote has no volume, and build it
    /// in again.
    public static let volumeUnavailable = true
}
