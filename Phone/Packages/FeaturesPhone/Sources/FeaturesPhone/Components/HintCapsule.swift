import DesignSystemPhone
import SwiftUI

/// A hint explains, an error reports.
///
/// **Two forms that must not be confused:** a hint in this form stands **above** the content,
/// demands nothing and disappears by itself — the current position while scrubbing, "Sound:
/// 60 %", "No program stored". An error gets a ``StateBlock`` with heading, sentence and
/// exactly one next step.
///
/// **It does not intercept touches.** A capsule that floats over the image and swallows swipe
/// gestures is in the way exactly where swiping is happening.
struct HintCapsule: View {

    /// Key in the catalog.
    var message: String?
    /// Finished wording — for numbers and times.
    var wording: String?

    var body: some View {
        Group {
            if let wording {
                Text(verbatim: wording)
            } else if let message {
                Text(appKey: message)
            }
        }
        .font(TypeLevel.header.font)
        .monospacedDigit()
        .minimumScaleFactor(0.5)
        .foregroundStyle(ColorRole.text.color)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Material.chromeBar, in: Capsule())
        .edge()
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}
