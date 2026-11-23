import DesignSystemPhone
import Downloads
import SwiftUI

/// Two targets in one row — **and always the same two.**
///
/// The title part opens the menu for the title, the button on the right operates the transfer.
/// Nested targets do not exist: Before, the two loading rows were a single button with a button
/// inside, and in a list that looks the same, two of seven rows did not react.
///
/// **The right button disappears where there is nothing to press** — for a finished file and
/// while waiting for the one connection. A dimmed button is an invitation whose answer is the
/// same every time.
struct DownloadRow: View {

    let job: DownloadJob
    /// `nil` if this title lies here finished.
    var transfer: Transfer?

    /// Whether a selection is going on and whether this row is part of it — **`nil` means: no
    /// selection.**
    ///
    /// **During selection the row has exactly one target, namely itself.** The control button steps
    /// down: Pausing and checking on the same row would be two meanings for one thumb — and one of
    /// them ends up taking something away.
    var isChecked: Bool?

    let menu: () -> Void
    let control: () -> Void

    private var action: TransferControl.Action {
        guard let transfer else { return .none }
        return TransferControl.action(forItem: transfer.state)
    }

    var body: some View {
        HStack(spacing: Metrics.targetSpacing) {
            Button(action: menu) {
                HStack(spacing: Metrics.targetSpacing) {
                    if let isChecked {
                        Image(
                            systemName: isChecked
                                ? Glyph.done.pair.filled : Glyph.done.pair.outlined
                        )
                        .iconSize(22)
                        .foregroundStyle(isChecked ? ColorRole.brandLight.color : ColorRole.textQuiet.color)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: job.title)
                            .font(TypeLevel.text.font)
                            .foregroundStyle(ColorRole.text.color)
                            .lineLimit(2)

                        if let beside = job.beside {
                            Text(verbatim: beside)
                                .font(TypeLevel.label.font)
                                .foregroundStyle(ColorRole.textQuiet.color)
                                .lineLimit(1)
                        }

                        stateRow
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isChecked == true ? .isSelected : [])

            if isChecked == nil, action != .none {
                Button(action: control) {
                    Image(systemName: icon)
                        .iconSize(17, weight: .medium)
                        .foregroundStyle(ColorRole.text.color)
                        .frame(width: Metrics.target, height: Metrics.target)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // **The label moves with the action.** A button whose image changes and whose label does not
                // says the wrong thing to the screen reader until the next launch — and nobody sees it.
                .accessibilityLabel(
                    Text(appKey: TransferControl.label(forItem: action)))
            }
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.vertical, Metrics.targetSpacing)
    }

    private var icon: String {
        switch action {
        case .pause: Glyph.pause.name
        case .resume: Glyph.play.name
        case .retry: Glyph.refresh.name
        case .none: ""
        }
    }

    /// **The state is a sentence and not a bar.** All three known failures of the competition are
    /// transport failures — the queue stops in the background, TLS breaks behind the reverse proxy,
    /// above two gigabytes nothing works at all. A bar shows the same for all three: nothing. That
    /// is why this says **what** is happening, and the bar below it only **how far**.
    @ViewBuilder
    private var stateRow: some View {
        if let transfer {
            Text(verbatim: TransferText.message(forItem: transfer).readable)
                .font(TypeLevel.label.font)
                .foregroundStyle(color(forItem: transfer.state))
                .lineLimit(2)

            if let portion = transfer.portion, case .isLoading = transfer.state {
                ProgressBar(portion: portion)
                    .padding(.top, 4)
            }
        }
    }

    private func color(forItem state: Transfer.Situation) -> Color {
        switch state {
        case .isLoading: ColorRole.textMatt.color
        case .failed: ColorRole.brandLight.color
        case .idle, .waitingForConnection: ColorRole.textQuiet.color
        case .done: ColorRole.textQuiet.color
        }
    }
}
