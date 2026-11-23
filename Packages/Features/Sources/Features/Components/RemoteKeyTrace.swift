import Core
import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// Writes every press on the remote into the key log
/// (``Diagnostics/keyPressed(_:)``).
///
/// **Since 2026-09-04 from UIKit, no longer from the game controller.** The
/// game controller reported the touch surface: a swipe across the surface tipped
/// the direction keys several times, a click on the ring arrived as a direction
/// **and** as a select — hence the duplicated and implausible lines
/// (F-008: "sometimes generates the key twice"). UIKit delivers exactly one
/// `UIPress` per press, and the very one SwiftUI builds its commands from:
/// what is recorded here is the press, and everything after it is measured against it.
///
/// A recogniser on the window sees every press before the views get it,
/// and passes it on untouched — it never recognises anything.
public enum RemoteKeyTrace {

    private static var started = false

    public static func start() {
        guard !started else { return }
        started = true
        #if canImport(UIKit) && os(tvOS)
            attachWhenWindowExists(attempt: 0)
        #endif
    }

    #if canImport(UIKit) && os(tvOS)
        private static var recognizer: PressLedgerRecognizer?

        private static func attachWhenWindowExists(attempt: Int) {
            let window =
                UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow }
                ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first
            guard let window else {
                guard attempt < 20 else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    attachWhenWindowExists(attempt: attempt + 1)
                }
                return
            }
            let ledger = PressLedgerRecognizer()
            window.addGestureRecognizer(ledger)
            recognizer = ledger
        }

        /// A recogniser that notes every press and claims none.
        private final class PressLedgerRecognizer: UIGestureRecognizer {
            init() {
                super.init(target: nil, action: nil)
                cancelsTouchesInView = false
                delaysTouchesBegan = false
                delaysTouchesEnded = false
                allowedPressTypes = [
                    NSNumber(value: UIPress.PressType.upArrow.rawValue),
                    NSNumber(value: UIPress.PressType.downArrow.rawValue),
                    NSNumber(value: UIPress.PressType.leftArrow.rawValue),
                    NSNumber(value: UIPress.PressType.rightArrow.rawValue),
                    NSNumber(value: UIPress.PressType.select.rawValue),
                    NSNumber(value: UIPress.PressType.menu.rawValue),
                    NSNumber(value: UIPress.PressType.playPause.rawValue),
                ]
            }

            override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
                for press in presses {
                    Diagnostics.keyPressed(Self.name(press.type))
                }
                // Never recognise: the press belongs to the view.
                state = .failed
            }

            override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
                state = .failed
            }

            override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
                state = .failed
            }

            static func name(_ type: UIPress.PressType) -> String {
                switch type {
                case .upArrow: "↑"
                case .downArrow: "↓"
                case .leftArrow: "←"
                case .rightArrow: "→"
                case .select: "Select"
                case .menu: "Menu"
                case .playPause: "Play/Pause"
                default: "Key \(type.rawValue)"
                }
            }
        }
    #endif
}
