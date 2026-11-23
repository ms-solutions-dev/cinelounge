import Foundation
import SwiftUI

// **`canImport(UIKit)` and not `os(tvOS)`** — the same correction that `VideoSurface`
// and `PictureInPicture` have already been through. The condition was from the start whether there is
// UIKit, and not which device is in front of it: `AVRoutePickerView` exists on iOS
// just the same, and there route selection is **more important** than on the TV — a phone
// switches between headphones, car and TV, a TV stays put.
#if canImport(UIKit)
    import AVKit
    import UIKit
#endif

/// The AirPlay button: The system's route selection, triggered by a
/// button of the bar (AP8).
///
/// **AirPlay already works** — AVPlayer allows playback on other
/// devices out of the box —, only the selection was missing. The system offers it
/// as `AVRoutePickerView`, a button of its own with a shape of its own; that
/// sits invisibly in the player, and the bar's button presses it. This way
/// the bar stays uniform, and the selection is the system's.
@MainActor
public final class AirPlayRouting {

    public static let shared = AirPlayRouting()

    #if canImport(UIKit)
        fileprivate var picker: AVRoutePickerView?
    #endif

    private init() {}

    /// Opens the route selection — `false` if there was no button to press.
    @discardableResult
    public func present() -> Bool {
        #if canImport(UIKit)
            guard let picker, let button = Self.button(in: picker) else { return false }
            button.sendActions(for: .primaryActionTriggered)
            return true
        #else
            return false
        #endif
    }

    #if canImport(UIKit)
        static func button(in view: UIView) -> UIButton? {
            if let button = view as? UIButton { return button }
            for child in view.subviews {
                if let found = button(in: child) { return found }
            }
            return nil
        }
    #endif
}

/// The invisible route selection — to be hooked into the player so that
/// ``AirPlayRouting/present()`` has something to press.
public struct AirPlayPickerAnchor: View {
    public init() {}

    public var body: some View {
        #if canImport(UIKit)
            Representable()
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
        #else
            EmptyView()
        #endif
    }

    #if canImport(UIKit)
        private struct Representable: UIViewRepresentable {
            func makeUIView(context: Context) -> AVRoutePickerView {
                let view = AVRoutePickerView()
                view.prioritizesVideoDevices = true
                AirPlayRouting.shared.picker = view
                return view
            }

            func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
        }
    #endif
}
