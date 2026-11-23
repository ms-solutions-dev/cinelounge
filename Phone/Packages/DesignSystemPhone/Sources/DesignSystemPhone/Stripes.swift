import Styling
import SwiftUI

/// The stripes of the popcorn bag — **wrapper around ``Styling/StripePattern``.**
///
/// - Important: **Since AP58 (2026-09-26)** rules, drawing and the dimensions of both devices
///   live in `Styling` (``Styling/StripeMetrics/phone``: six points, as in the bag of
///   the logo; narrower turns to moiré at 1×). This wrapper takes the chosen
///   ``Styling/ColorBoard/current`` and the phone's dimensions, so that the call sites can
///   stay.
public struct StripeBand: View {

    /// How wide a single stripe is.
    public static let stripeWidth: CGFloat = StripeMetrics.phone.stripeWidth

    private let opacity: Double

    public init(opacity: Double = 1) {
        self.opacity = opacity
    }

    public var body: some View {
        StripePattern(board: ColorBoard.current, metrics: .phone, opacity: opacity)
    }
}

extension View {

    /// A short stripe in front of a heading — the quietest use of the pattern.
    public func withBrandStripe(
        width: CGFloat = StripeMetrics.phone.strokeWidth,
        height: CGFloat = StripeMetrics.phone.strokeHeight
    ) -> some View {
        withStripeStroke(board: ColorBoard.current, metrics: .phone, width: width, height: height)
    }
}

/// The loading band — **wrapper around ``Styling/LoadingTrack``** with the phone's dimensions:
/// four points tall, across the full width.
public struct LoadingBand: View {

    public init() {}

    public var body: some View {
        LoadingTrack(board: ColorBoard.current, metrics: .phone)
    }
}
