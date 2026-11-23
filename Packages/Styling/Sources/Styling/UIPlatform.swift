/// Which device a value applies to.
///
/// **A parameter and not a switch at compile time.** `#if os(tvOS)` would have made the TV's
/// values invisible on the Mac, and that is where the checks of both programs run —
/// the TV test suite would get the phone's numbers and not notice. This way
/// each platform layer names its device once (`DesignSystem` says ``tv``,
/// `DesignSystemPhone` ``phone``), and every check can read both sides side by side.
///
/// **The iPad is ``phone``.** It shares programme, thumb and text styles with the phone; what
/// becomes wider there is decided by the size class in the phone programme, not by this board.
public enum UIPlatform: String, Sendable, CaseIterable {
    /// 1920 × 1080 points at three metres, focus instead of finger, no Dynamic Type.
    case tv = "fernseher"
    /// 393 × 852 points at thirty centimetres, thumb, text styles with Dynamic Type.
    case phone = "handy"
}
