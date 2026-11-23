import CoreGraphics
import SwiftUI

/// **Which form the app currently has** — the familiar one or that of a child (AP45,
/// owner decision 7; since G3 on 2026-09-26 on both devices).
///
/// **Not a second app, but the same frame with a different plan** (concept
/// `design/konzept-childInterface.md`, section 3). Until G3 this value existed only in the
/// TV package, and the phone knew for a child only the scope (tabs are dropped),
/// not the form (finding B3 in the feature comparison). **The rules stand here
/// once, the dimensions come from the device's ``MetricsBoard``** — the same separation as in the
/// rest of this package: roles shared, numbers per device.
///
/// **It follows the kind of profile and not the device lock.** The device lock is a
/// limit for content, the child UI a form for children: Whoever signs in as an adult with their
/// PIN gets their familiar app. That is why ``forItem(kind:)`` takes
/// only the kind; what a child may see is decided by `ParentalControls.ChildScope`.
public enum Surface: Equatable, Sendable {

    /// The app as every adult knows it.
    case familiar

    /// Larger tiles, less text, few entries and a way out.
    case kind

    /// The form for a profile of this kind — **the familiar one without a profile.** A device before
    /// first setup has nobody sitting in front of it yet; giving it the child UI
    /// would mean hiding setup behind "Switch profile".
    public static func forItem(kind: Bool) -> Surface {
        kind ? .kind : .familiar
    }

    // MARK: - The tiles

    /// By how much a child's posters are larger: **1.3 — on both devices.**
    ///
    /// **Calculated from the number of posters on screen.** On the TV at 240 points
    /// six stand side by side, at 312 barely five; on the phone from three visible a good two.
    /// Enough to recognise a row as a row, and large enough that a child reads the picture
    /// and not the text.
    public static let childScale: CGFloat = 1.3

    /// The factor by which this form enlarges a tile.
    public var reference: CGFloat {
        switch self {
        case .familiar: 1
        case .kind: Self.childScale
        }
    }

    /// The size of a poster in this form — **with the device's board.**
    public func posterSize(to board: MetricsBoard) -> CGSize {
        CGSize(width: board.poster.width * reference, height: board.poster.height * reference)
    }

    /// A measured tile width in this form — for devices that calculate their tiles from
    /// the available space (the phone, ``MetricsBoard/phone``) instead of fixing them.
    public func enlarged(_ measured: CGFloat) -> CGFloat {
        (measured * reference).rounded(.down)
    }

    /// Whether "Continue Watching" carries still frames in widescreen format.
    ///
    /// **Not for a child:** A still frame from the middle of the episode is not recognised, the
    /// poster of the series is.
    public var showsWideImages: Bool { self == .familiar }

    /// Whether the header image shows synopsis, meta line and ratings.
    ///
    /// **"Less text"** from the owner's brief: Title and a press are enough for
    /// someone who does not read the synopsis.
    public var showsExtras: Bool { self == .familiar }
}

extension EnvironmentValues {

    /// The form of the views below — **set in ONE place per device** (on the phone
    /// the shell), read where tiles and header image are drawn.
    @Entry public var surface: Surface = .familiar
}
