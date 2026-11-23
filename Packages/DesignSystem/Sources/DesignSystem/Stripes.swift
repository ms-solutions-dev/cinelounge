import Styling
import SwiftUI

/// The stripes of the popcorn bag — **the pattern that belongs to this app.**
///
/// **Taken over from the phone** (AP27, 2026-09-11), namely the rules unchanged, the
/// numbers not. There the client rejected a pure typeface exchange as a
/// distinguishing feature — rightly so: a grotesque appears in ten thousand apps.
/// What makes CineLounge unmistakable lies in `design/logo.svg`: the red armchair with
/// the striped bag. The armchair now stands in the sidebar
/// (``Features/AppSidebar``); but the strongest **transferable** part is not it,
/// but the stripes.
///
/// **A pattern can do what a typeface cannot: be applied.** A
/// type family is seen in three places. A pattern may appear in thirty and still
/// not get loud — as long as it stays small. Three rules follow from that, and they
/// stand here and not at the call sites:
///
/// * **Never wider than an edge.** As a band, as a line — never as a surface.
/// * **Never behind text.** A striped background under a word lowers its contrast
///   to the worst of its two stripes, and with red on cream that is no
///   longer a matter of taste.
/// * **Never as information.** It does not say "live" and not "loading" — it says "this app".
///   What carries a meaning stands next to it as a word.
///
/// **The four-point limit does NOT come along, and that is calculated.** On the phone
/// one point is 1.89 arcminutes (arm's length); on the TV it is **0.73** (three meters).
/// Four points here would be 2.9′ — invisible. **The equivalent is 10–12 pt**,
/// the stripe width 6 becomes **12–14 pt**. Whoever transfers the phone's numbers
/// transfers its viewing conditions too, and those do not exist here.
///
/// **The colors come from the color board and not from the logo.** The logo carries
/// `#FFF8E9`; the board carries ``Styling/ColorRole/text``, and the two are close
/// together. The board is used — otherwise the app would have a second cream color that
/// would stay put on a theme switch.
///
/// - Important: **Since AP58 (2026-09-26) a wrapper** around ``Styling/StripePattern`` with the
///   measures ``Styling/StripeMetrics/tv``. Rules and drawing live there, once
///   for both devices.
public struct StripeBand: View {

    /// How wide a single stripe is.
    ///
    /// **Thirteen and not six.** Six points on the TV are 4.4 arcminutes —
    /// two of them side by side merge from the couch into a single gray tone,
    /// and the pattern becomes a surface. Thirteen correspond to the phone's six.
    ///
    /// **`nonisolated`, because a measurement needs no actor.** ``StripeBand`` is
    /// a `View` and thus `@MainActor`; its static constants inherit that, and
    /// a check outside the main thread then cannot reach them. The
    /// **debug build let it pass, the release build did not** — for the third time on
    /// 2026-09-11 it was the stricter checker. A number is a number.
    public nonisolated static let stripeWidth: CGFloat = StripeMetrics.tv.stripeWidth

    /// How tall a band is when nothing else is specified.
    ///
    /// **Eleven and not four** — the same conversion. Four points would be 2.9′ and thus
    /// below the threshold at which a line is read as a line at all.
    public nonisolated static let bandHeight: CGFloat = StripeMetrics.tv.bandHeight

    private let opacity: Double

    public init(opacity: Double = 1) {
        self.opacity = opacity
    }

    public var body: some View {
        StripePattern(board: ColorBoard.current, metrics: .tv, opacity: opacity)
    }
}

/// The loading band — **instead of the gray system spinner.**
///
/// **Why exactly here** (AP27, 2026-09-11): the tree contained **21 bare
/// `ProgressView()`**. A system spinner measures about one point at three meters; it says
/// "something is turning", and does so identically in every app. A band across the shelf width
/// is a statement — **that is the largest single effect of this package**, because this app
/// loads often and for long, and the loading state is thus one of the most-seen screens.
///
/// **And exactly for that reason it has to stay quiet:** what one sees a hundred times must not
/// want to stand out.
///
/// **With "Reduce Motion" nothing runs.** Then the band stands still at the start — the
/// information "something is loading here" is carried by the sentence beside it, which ``StateView``
/// requires anyway. Less motion, not no feedback at all.
public struct LoadingBand: View {

    /// How wide the track gets at most.
    ///
    /// **A band across the whole screen width would no longer be feedback but
    /// a bar.** The number is this app's reading width — the same one that a
    /// paragraph does not exceed.
    public nonisolated static let laneWidth: CGFloat = StripeMetrics.tv.laneWidth ?? .infinity

    public init() {}

    public var body: some View {
        LoadingTrack(board: ColorBoard.current, metrics: .tv)
    }
}

extension View {

    /// A short stripe before a heading — the quietest application of the pattern.
    ///
    /// **Before the heading and not below it.** A line under the row reads
    /// as a divider and thus as information about what follows; one before it belongs to the
    /// row itself.
    public func withBrandStripe(
        width: CGFloat = StripeMetrics.tv.strokeWidth,
        height: CGFloat = StripeBand.bandHeight
    ) -> some View {
        withStripeStroke(board: ColorBoard.current, metrics: .tv, width: width, height: height)
    }
}
