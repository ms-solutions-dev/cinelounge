import DesignSystemPhone
import Downloads
import SwiftUI

/// How a title stands in downloads — **three states, one control.**
///
/// **The button is also the display, and that is the whole design.** A separate progress bar
/// next to it would be a second place saying the same thing; a button that only says "download"
/// would leave the question "is this running right now?" unanswered. Netflix and the ARD
/// Mediathek both do the same, for the same reason.
public enum DownloadState: Equatable, Sendable {

    /// Not queued yet — the outline.
    case notQueued

    /// Loading. The fraction is `nil` as long as the total size is unknown; then the ring spins
    /// instead of claiming a number.
    case isLoading(Double?)

    /// Available here — filled.
    case isHere

    /// Paused or waiting. **A state of its own and not "loading with a pause":** A half-filled ring
    /// that does not move looks like an error; this looks like an interruption, because it is one.
    case idle(Double?)
}

/// The button for downloads — on the detail page, on the episode row and on the season header.
///
/// **It is visible and not in the ⋯ menu.** That was the finding of 2026-09-08: "visually there is
/// still no obvious point at all for how and where content can be downloaded". It was right —
/// "Add to downloads" lived only in the overflow menu, and a feature there does not exist for
/// most users. Missing downloads are the documented churn reason no. 1 at Swiftfin; a hidden
/// download is the same thing, only with more effort.
///
/// **What is labeled is the thing and not the action** — the same rule as at ``RoundButton``.
/// "Add to downloads" does not fit into 44 points, and what the press does depends on the
/// state: queue, pause, remove.
struct DownloadButton: View {

    let state: DownloadState
    /// Smaller for the episode row — there it stands next to a row and not in a line of equally
    /// sized buttons.
    var lowercased = false
    let action: () -> Void

    private var size: CGFloat { lowercased ? 34 : Metrics.target }

    var body: some View {
        Button(action: action) {
            ZStack {
                if case .isLoading(let portion) = state {
                    Ring(portion: portion, isSpinning: portion == nil)
                } else if case .idle(let portion) = state {
                    Ring(portion: portion, isSpinning: false)
                        .opacity(0.55)
                }
                Image(systemName: icon)
                    .iconSize(lowercased ? 14 : 17, weight: .medium)
                    .foregroundStyle(color)
            }
            .frame(width: size, height: size)
            .background(lowercased ? Color.clear : ColorRole.surface.color, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(appKey: label))
        // **The state is a trait and not a second name.** A screen reader then says "Add to
        // downloads, loading" instead of two buttons with different names between which nobody hears a
        // connection.
        .accessibilityValue(Text(appKey: stateName))
    }

    private var icon: String {
        switch state {
        case .notQueued: Glyph.downloads.name
        case .isLoading: Glyph.pause.name
        case .idle: Glyph.play.name
        case .isHere: Glyph.done.pair.filled
        }
    }

    private var color: Color {
        switch state {
        case .isHere: ColorRole.success.color
        case .notQueued, .isLoading, .idle: ColorRole.text.color
        }
    }

    private var label: String { "stock.putInStock" }

    private var stateName: String {
        switch state {
        case .notQueued: "stock.state.notDownloaded"
        case .isLoading: "stock.state.downloading"
        case .idle: "common.paused"
        case .isHere: "stock.state.downloaded"
        }
    }
}

/// The progress ring around the symbol.
///
/// **Without a known size it spins instead of standing at zero.** A ring at zero claims that
/// nothing has happened yet — but with a portal the size is only known after the first block,
/// and by then something has long since happened.
private struct Ring: View {

    let portion: Double?
    let isSpinning: Bool

    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(ColorRole.text.color.opacity(0.18), lineWidth: 2)
            Circle()
                .trim(from: 0, to: portion ?? 0.25)
                .stroke(ColorRole.brandLight.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90 + rotation))
        }
        .padding(3)
        // **One revolution per pass and not an endless one.** A repeating animation in SwiftUI is not
        // a state that a new value ends — it keeps driving the property, and a reset pushed in
        // afterward is overwritten. That is exactly what kept the sync button spinning for the rest of
        // the session on 2026-09-07.
        .task(id: isSpinning) {
            guard isSpinning else { return }
            while !Task.isCancelled {
                withAnimation(.linear(duration: 1)) { rotation += 360 }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

extension DownloadState {

    /// The state of a title from what downloads know.
    ///
    /// **One place and not three.** Detail page, episode row and season header ask the same
    /// question; anyone who answered it three times would have two correct answers and an old one
    /// at the next state.
    static func forItem(_ identifier: DownloadJob.Identifier, in downloads: Downloads) -> DownloadState {
        if let running = downloads.isRunning.first(where: { $0.id == identifier }) {
            switch running.state {
            case .isLoading: return .isLoading(running.portion)
            case .idle, .waitingForConnection: return .idle(running.portion)
            case .failed: return .idle(running.portion)
            case .done: return .isHere
            }
        }
        return downloads.items.contains { $0.id == identifier } ? .isHere : .notQueued
    }
}
