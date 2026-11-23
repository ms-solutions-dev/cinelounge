import DesignSystemPhone
import SwiftUI

/// The follow-up question: the episodes before it too?
///
/// **Two buttons, both equally loud — because it is a question and not a recommendation.** Whoever
/// starts at episode 22 has either watched the 21 before it or not; the app does not know it
/// better than they do. One loud and one quiet button would be an answer we cannot
/// give.
///
/// **The number is in the question.** "The 21 episodes before it too?" is a different question than
/// "The 2 episodes before it too?" — and with 21 you really think about it.
struct PriorEpisodesSheet: View {

    let count: Int
    let onlyThis: () -> Void
    let alsoBefore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            Text(app: "detail.alsoEarlier \(count)")
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(appKey: "detail.alsoEarlierWhy")
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: MetricsBoard.phone.gutter)

            Button(action: alsoBefore) {
                Text(app: "detail.alsoEarlierYes \(count)")
            }
            .buttonStyle(.loud)

            Button(action: onlyThis) {
                Text(appKey: "detail.markEarlierOnly")
            }
            .buttonStyle(.quiet)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.top, MetricsBoard.phone.section)
        .padding(.bottom, MetricsBoard.phone.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
