import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// **The only view that rotates.**
///
/// A film is landscape; everything else in this app stands upright. The app therefore allows
/// only portrait overall (`project.yml`), and **this** view lifts the rule for
/// itself — not the other way round. Whoever builds it the other way round rotates the library along, and a
/// three-column poster grid in landscape is no longer a library.
///
/// **Nothing is forced.** `requestGeometryUpdate` proposes an orientation; whoever has locked
/// their device keeps it. A player that overrides the rotation lock is exactly
/// the one everybody complains about — it rotates in bed.
///
/// **It is handed back on disappearing**, and explicitly: without that the
/// permission would stay, and the next screen would lie sideways.
struct Rotation: ViewModifier {

    func body(content: Content) -> some View {
        #if canImport(UIKit)
            content
                .onAppear { set(.allButUpsideDown) }
                .onDisappear { set(.portrait) }
        #else
            content
        #endif
    }

    #if canImport(UIKit)
        private func set(_ situations: UIInterfaceOrientationMask) {
            guard
                let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first
            else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: situations))
            // **The controller must know too.** The scene asks it at the next
            // rotation, and without this line the view falls straight back into portrait.
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    #endif
}

extension View {

    /// Allows this view the landscape orientation — and takes it back on disappearing.
    func withRotation() -> some View { modifier(Rotation()) }
}
