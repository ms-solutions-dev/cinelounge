import Core
import DesignSystem
import SwiftUI

/// A1 after the clip — **the word mark and "Looking at iCloud …", without focus** (AP88 §2.6).
///
/// The intro does not get longer for iCloud (rule L from AP51); it is a cover and not an
/// appointment. Whoever still waits for the answer when the clip is gone sees this quiet page for
/// at most ``Flows/SetupMachine/cloudGrace``, then A2 comes with or without the profiles.
///
/// **It also stands under the clip**, so that the intro fades onto the same page and not onto a
/// black frame that then jumps.
///
/// **Nothing to focus:** the Menu button sends the app to the background, as on every tvOS app;
/// the next start resumes where the book stands.
struct CloudWaitView: View {

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            SetupWordmark()
            HStack(spacing: 18) {
                ProgressView()
                Text(app: "setup.cloudWait")
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.textMatt.color)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The word mark of the setup pages — the same letters as on the old sign-in screen.
struct SetupWordmark: View {

    var body: some View {
        Text(verbatim: "CINELOUNGE")
            .font(TypeLevel.title.font)
            .kerning(10)
            .foregroundStyle(ColorRole.text.color)
            .accessibilityHidden(true)
    }
}
