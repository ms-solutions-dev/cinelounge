import Foundation

/// The contract behind which both possibilities lie.
///
/// **So that measurement M3 afterwards swaps an implementation and not the views.**
/// Two paths were up for choice: the wire of its own over Bonjour (``OwnWire``) and
/// Jellyfin's session commands (``JellyfinSitzungsweg``). The second would have been cheaper
/// and controls **one** of the three sources — for a channel and for a portal the
/// media server knows nothing about what plays on the TV. That is why the own wire is
/// built and the other stays as scaffolding.
///
/// **The contract stays regardless.** It costs thirty lines and is the place at which
/// the remote view **need not** know what it is talking over. Without it, every
/// view would hang on `NWConnection`.
///
/// **An actor and not a protocol with `@MainActor`.** A connection lives beside the
/// UI; whoever binds it to the main thread holds it up with every packet.
public protocol ControlPath: Actor {

    /// Whether the connection is up.
    var connected: Bool { get }

    /// Connect — and **wait until the TV has answered.**
    ///
    /// **Not "kick off and return".** The screen waiting for it has exactly
    /// two honest states: "connecting" and "up". A third — "maybe connected"
    /// — would be the kind of information that makes you think the app is broken.
    func connect(using target: DeviceDiscovery.Device) async throws

    /// Release the connection.
    func disconnect() async

    /// Send a command.
    ///
    /// **Without receipt, and deliberately.** A jump that has to be confirmed costs
    /// a round trip before the picture moves; what really happened is told by the
    /// next ``StateMirror`` — and that comes anyway. What goes wrong is reported by the
    /// error of this function, not by a missing "yes".
    func send(_ command: Command) async throws

    /// The stream of states from the TV.
    ///
    /// **A stream and not a callback.** A callback would have to say on which thread it
    /// arrives; a stream lets the reader decide, and the reader is a view.
    /// **`nonisolated`, because it is read from outside.** The stream is created once at
    /// setup and never changes; making it part of the actor would mean a view
    /// first has to wait for the actor just to be allowed to listen — and at
    /// every redraw.
    nonisolated var states: AsyncStream<StateMirror> { get }
}
