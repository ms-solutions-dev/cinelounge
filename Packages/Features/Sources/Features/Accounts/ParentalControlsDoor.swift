import DesignSystem
import SwiftUI

/// Puts a parental-controls door in front of any screen.
///
/// **Why this wrapper exists.** ``ParentalControlsState`` and ``PinSheet`` are
/// package-internal and are meant to stay so — they are internals of the settings. The
/// **receiving screen of the device handoff** however lives in the app and not in this
/// package (`App/Sources/Login`), and it needs the same door. The choice was between
/// "making the holder public" and "making a door public"; **a door is the
/// smaller commitment**: Whoever uses it cannot bypass, reconfigure or
/// read out the lock — they can only stand behind it.
///
/// **It brings its own holder, and that is right here.** The settings
/// keep a ``ParentalControlsState`` for their whole view, because two holders could
/// disagree about the same state. This screen sits in the
/// sign-in path — outside the settings, often before there is any account at all —,
/// and a pass handed through from there would be exactly the wrong thing: Whoever was in the settings
/// two minutes ago has not thereby released someone else's TV.
///
/// **On first setup it costs nothing.** ``ProtectionRule/applies`` requires a
/// PIN to be set; without one every door is open, and that is exactly when a handoff runs.
public struct ParentalControlsDoor<Content: View>: View {

    private let door: String
    private let content: Content

    @StateObject private var lock = ParentalControlsState()

    /// - Parameter tuer: The identifier from ``ParentalControls/LockedDoors``.
    public init(_ door: String, @ViewBuilder content: () -> Content) {
        self.door = door
        self.content = content()
    }

    public var body: some View {
        Group {
            if lock.isHidden(door) {
                Curtain(
                    door: door,
                    reason: lock.reason(forItem: door),
                    asks: { lock.queryPending(door) }
                )
                .padding(60)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .background(ColorRole.reason.color)
            } else {
                content
            }
        }
        .background(pinSheet)
    }

    /// The same sheet as in the settings — **above everything and not beneath.**
    @ViewBuilder
    private var pinSheet: some View {
        #if os(tvOS)
            Color.clear.fullScreenCover(
                isPresented: Binding(
                    get: { lock.openQuestion != nil },
                    set: { if !$0 { lock.cancel() } }
                )
            ) {
                PinDoorSheet(lock: lock)
            }
        #endif
    }
}
