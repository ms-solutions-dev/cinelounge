import SwiftUI

/// How far a row indents left and right — **one number, and the environment carries it.**
///
/// **The finding of 2026-09-07, and it stood in the just-converted screens themselves.** A row on
/// the background indents by ``Styling/MetricsBoard/margin`` (20 points, measured from the
/// screen edge); a row **in a card** indents by ``Metrics/cardInset`` (14, measured from the
/// card edge, which itself is already 20 from the screen). That is two numbers for two cases,
/// and both are right.
///
/// **What was wrong was that every row itself knew which case it is in.** On 2026-09-07 in
/// `AboutView` a ``ValueRow`` (14) and a ``DisclosureRow`` (20) stood one above the other **in
/// the same card** — their texts started seven points offset, and the ``Separator`` between
/// them lay on a third edge. Nobody noticed, because none of the three building blocks was
/// wrong: each carried the number that applied to it.
///
/// **That is why now the card says it and not the row.** ``SettingsCard`` sets this
/// value for everything that lies in it; whoever stands outside gets the default. A row can
/// thereby stand in both places without knowing a number — and a seventh building block that
/// is added tomorrow sits right by itself.
///
/// The same lesson as with ``SwipeCommands`` on the same day: what is maintained in several
/// places drifts apart as soon as one of them is not touched.
private struct RowInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = MetricsBoard.phone.margin
}

extension EnvironmentValues {

    /// The horizontal inset of a settings row.
    ///
    /// **Set in one place only** — by ``SettingsCard``. Whoever sets it elsewhere has two
    /// truths again.
    public var rowInset: CGFloat {
        get { self[RowInsetKey.self] }
        set { self[RowInsetKey.self] = newValue }
    }
}
