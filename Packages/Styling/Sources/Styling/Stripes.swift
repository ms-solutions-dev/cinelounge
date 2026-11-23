import SwiftUI

/// The dimensions of the stripe pattern per device — **the rules shared, the numbers not.**
///
/// The stripes of the popcorn bag from `design/logo.svg` are the pattern that belongs
/// to this app. Three rules apply on both devices and therefore stand once here:
///
/// * **Never wider than an edge.** As a band, as a stroke — never as a surface.
/// * **Never behind text.** A striped ground lowers the contrast of a word to that of the
///   worse of its two stripes.
/// * **Never as information.** It does not say "live" and not "loading" — it says "this app".
///
/// **The numbers are calculated, not carried over.** On the phone a point stands for 1.89
/// arc minutes (arm's length), on the TV for 0.73 (three metres). Six points of stripe on the
/// phone correspond to about thirteen on the TV; four points of band height would be 2.9′ there and
/// thus invisible.
///
/// **The colours come from the colour board** (``ColorRole/text`` and ``ColorRole/tag``) and
/// not from the logo — otherwise the app would have a second cream colour that would stay put
/// on a scheme change.
public struct StripeMetrics: Sendable, Equatable {
    /// Breite eines einzelnen Streifens.
    public let stripeWidth: CGFloat
    /// Height of a band if nothing else is said — also of the loading band.
    public let bandHeight: CGFloat
    /// Width of the stroke before a heading.
    public let strokeWidth: CGFloat
    /// Height of the stroke before a heading.
    public let strokeHeight: CGFloat
    /// Distance between stroke and heading.
    public let strokeSpacing: CGFloat
    /// How wide the track of the loading band becomes at most — `nil` means the full width.
    ///
    /// On the TV the app's reading width: A band across the full screen width would no longer be
    /// feedback but a bar.
    public let laneWidth: CGFloat?

    public static func forItem(_ platform: UIPlatform) -> StripeMetrics {
        switch platform {
        case .tv: tv
        case .phone: phone
        }
    }

    public static let tv = StripeMetrics(
        stripeWidth: 13, bandHeight: 11, strokeWidth: 64, strokeHeight: 11, strokeSpacing: 16,
        laneWidth: 620)

    public static let phone = StripeMetrics(
        stripeWidth: 6, bandHeight: 4, strokeWidth: 34, strokeHeight: 3, strokeSpacing: 9,
        laneWidth: nil)
}

/// A band made of the stripes — drawn with `Canvas`, because only while drawing is it known
/// how many fit in; a stack of views would create a view of its own per stripe.
///
/// **Not present for the screen reader** — it carries no information.
public struct StripePattern: View {

    private let board: ColorBoard
    private let metrics: StripeMetrics
    private let opacity: Double

    public init(board: ColorBoard, metrics: StripeMetrics, opacity: Double = 1) {
        self.board = board
        self.metrics = metrics
        self.opacity = opacity
    }

    public var body: some View {
        let light = Color(.text, in: board)
        let tag = Color(.tag, in: board)
        let width = metrics.stripeWidth
        Canvas { context, size in
            var x: CGFloat = 0
            var isLight = true
            while x < size.width {
                context.fill(
                    Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                    with: .color(isLight ? light : tag))
                x += width
                isLight.toggle()
            }
        }
        .opacity(opacity)
        .accessibilityHidden(true)
    }
}

/// The loading band — **instead of the grey system spinner.**
///
/// This app loads often and for long; the loading state is one of the most-seen screens.
/// Exactly for that reason it looks like it belongs to the app — and exactly for that reason it stays quiet. **With "Reduce
/// Motion" nothing runs**: The information "something is loading here" is carried by the sentence next to it.
public struct LoadingTrack: View {

    /// How wide the running piece is, as a fraction of the track.
    private static let portion: CGFloat = 0.42

    private let board: ColorBoard
    private let metrics: StripeMetrics

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inFlight = false

    public init(board: ColorBoard, metrics: StripeMetrics) {
        self.board = board
        self.metrics = metrics
    }

    public var body: some View {
        GeometryReader { surface in
            let width = surface.size.width * Self.portion
            StripePattern(board: board, metrics: metrics)
                .frame(width: width)
                .clipShape(Capsule())
                .offset(x: inFlight ? surface.size.width : -width)
                .animation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: 1.9).repeatForever(autoreverses: false),
                    value: inFlight)
        }
        .frame(maxWidth: metrics.laneWidth)
        .frame(height: metrics.bandHeight)
        .background(Color(.surfaceHigh, in: board), in: Capsule())
        .clipShape(Capsule())
        .onAppear { inFlight = !reduceMotion }
        .accessibilityHidden(true)
    }
}

extension View {

    /// A short stripe before a heading — the quietest application of the pattern.
    ///
    /// **Before the heading and not below it.** A stroke under the line reads as a
    /// divider and thus as information about what follows; one before it belongs to the line.
    public func withStripeStroke(
        board: ColorBoard, metrics: StripeMetrics, width: CGFloat? = nil, height: CGFloat? = nil
    ) -> some View {
        HStack(spacing: metrics.strokeSpacing) {
            StripePattern(board: board, metrics: metrics)
                .frame(width: width ?? metrics.strokeWidth, height: height ?? metrics.strokeHeight)
                .clipShape(Capsule())
            self
        }
    }
}
