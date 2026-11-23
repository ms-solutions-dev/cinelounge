import CoreGraphics

/// What the player reports over the picture — **each message with its own place.**
///
/// **The finding of 2026-09-25, on the iPhone in portrait:** The time while seeking lay as
/// a capsule exactly under the pause button, the confirmation of a double tap ("10 s")
/// exactly on the +30 button. Both times the cause was the same: The messages hung as
/// `overlay(alignment: .center)` or `.trailing` on the whole swipe surface and calculated
/// their location **from the screen size**, while the buttons stood **in a different
/// stack** (``TransportRow`` in the bar of ``PlayerView``) and calculated theirs from
/// the space between header and timeline. Neither side knew of the other. In landscape it
/// happened to go well (the middle of the right half lies far from +30 there), in portrait
/// the two met to within a few points.
///
/// **The order is the precedence.** Whoever is placed first gets their preferred place;
/// whoever comes later yields within their zone or takes the next one. The still frame
/// comes first because it is the only one that stays until something changes.
nonisolated enum Feedback: CaseIterable, Hashable, Sendable {
    /// The board "the picture is still" — see ``PlayerModel/settled``.
    case stall
    /// The total of a double tap on the left — see ``JumpIndicator``.
    case skipBack
    /// The total of a double tap on the right.
    case skipForward
    /// The time while seeking with the finger.
    case time
    /// The brightness bar, on the left.
    case levelLeft
    /// The volume bar, on the right.
    case levelRight
    /// "2×", while pressed.
    case rate
    /// The picture layout after pinching.
    case pictureState
    /// A sentence on why something did not happen — see ``PlayerView``.
    case hint

    /// How fleeting the message is — **the more fleeting one yields in the fallback.**
    ///
    /// The board stays until something changes; the short hint and the picture layout stay a
    /// few seconds; what the finger is doing right now is already a different thing at the
    /// next intermediate frame. If a message finds no free place, the more fleeting one drops
    /// out instead of two standing on top of each other (finding B2, 2026-09-25).
    var volatility: Int {
        switch self {
        case .stall: 0
        case .hint, .pictureState: 1
        case .skipBack, .skipForward, .time, .levelLeft, .levelRight, .rate: 2
        }
    }
}

/// Where the feedback appears — **calculated and not decided in the body of the view.**
///
/// **The buttons are measured, the messages avoid them.** Free is only what lies between
/// header and timeline and does not belong to the transport row. From that come four zones
/// (above, below, left and right of the row), and each message has a list of preferred
/// places within them. An offset "so many points below the middle" would have had the same
/// gap as the old build: It holds for one font size, one screen orientation and one
/// device.
///
/// **The guarantee is the zone and not the preference.** If a message fits nowhere at its
/// natural size, it is measured in its zones with their height — the views become more
/// compact in the process (smaller font, fewer lines, without icon). **Only what fits the
/// zone when measured that way is placed**; until 2026-09-25 only the rectangle was
/// shortened here, and the view drew beyond it at its full height (finding B1).
/// `FeedbackPlacementTests` recalculates this for small and large devices, both
/// orientations and the largest font.
nonisolated enum FeedbackSlots {

    /// The measured frames of the controls, in the space of the control surface.
    ///
    /// **Whole rows and not single buttons.** Whoever avoids the row avoids every button in it
    /// — and between −10 and pause there is no room for a message that is meant to be read
    /// anyway.
    struct Buttons: Equatable, Sendable {
        /// Back, title and the button row at the top.
        var header: CGRect
        /// −10, Pause, +30.
        var transport: CGRect
        /// Timeline with times and the button for the next episode.
        var bar: CGRect

        init(header: CGRect, transport: CGRect, bar: CGRect) {
            self.header = header
            self.transport = transport
            self.bar = bar
        }

        /// What applies as long as nothing has been measured yet: nothing at the top, nothing at
        /// the bottom, one point in the middle.
        ///
        /// **Only for the first drawing pass.** The bar is there at start, and its frames come in
        /// the same pass; after that the measurement replaces this assumption.
        static func unmeasured(in surface: CGRect) -> Buttons {
            Buttons(
                header: CGRect(x: surface.minX, y: surface.minY, width: surface.width, height: 0),
                transport: CGRect(x: surface.midX, y: surface.midY, width: 0, height: 0),
                bar: CGRect(x: surface.minX, y: surface.maxY, width: surface.width, height: 0))
        }

        /// All three, for the check "never on a button".
        var all: [CGRect] { [header, transport, bar] }
    }

    /// The free areas around the transport row.
    enum Zone: Sendable {
        case top, bottom, links, right
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// Where a message moves within its zone.
    enum Anchor: Sendable { case start, midpoint, end }

    /// A preferred place: the zone and how the message sits in it.
    struct Request: Sendable {
        let zone: Zone
        let horizontal: Anchor
        let vertical: Anchor
    }

    /// The distance to the buttons and between the messages.
    ///
    /// **The app's gap** (`MetricsBoard.phone.gutter`), here as a number because this calculation
    /// should work without the main thread.
    static let spacing: CGFloat = 12

    /// How wide a sentence gets at most, even if the zone is wider.
    ///
    /// **Nobody reads a line across the full width of an iPad.** Beyond it the sentence wraps;
    /// the number is the text width the app also uses for status texts.
    static let maxWidth: CGFloat = 440

    /// Where a message wants to stand, in the order of preference.
    ///
    /// **The jump on its side.** Next to the row when there is room (landscape and on iPad),
    /// otherwise **above** the button on its side and never on it — in portrait there is only
    /// a strip of a good sixty points next to +30. The side remains part of the information:
    /// right means forward.
    ///
    /// **The time while seeking directly above the timeline**, where the eye is while seeking
    /// anyway, and no longer in the middle. In landscape with the largest font, not even the
    /// edge of a capsule is free above and below the row; then it sits at the bottom in a side
    /// strip instead of being missing entirely.
    ///
    /// **The still frame directly under the header.** It stays until something changes; the
    /// middle belongs to the pause button, and at the bottom the time appears while seeking.
    static func wishes(_ report: Feedback) -> [Request] {
        switch report {
        case .stall:
            [
                Request(zone: .top, horizontal: .midpoint, vertical: .start),
                Request(zone: .bottom, horizontal: .midpoint, vertical: .end),
                Request(zone: .links, horizontal: .midpoint, vertical: .midpoint),
                Request(zone: .right, horizontal: .midpoint, vertical: .midpoint),
            ]
        // **In landscape, top and bottom are only one line high each**, but next to the row a
        // third of the width is free. Whoever cannot fit in there moves to the upper or lower
        // edge of a side strip.
        case .rate, .pictureState:
            [
                Request(zone: .top, horizontal: .midpoint, vertical: .start),
                Request(zone: .bottom, horizontal: .midpoint, vertical: .end),
                Request(zone: .links, horizontal: .midpoint, vertical: .start),
                Request(zone: .right, horizontal: .midpoint, vertical: .start),
            ]
        case .hint:
            [
                Request(zone: .bottom, horizontal: .midpoint, vertical: .end),
                Request(zone: .top, horizontal: .midpoint, vertical: .start),
                Request(zone: .right, horizontal: .midpoint, vertical: .end),
                Request(zone: .links, horizontal: .midpoint, vertical: .end),
            ]
        case .time:
            [
                Request(zone: .bottom, horizontal: .midpoint, vertical: .end),
                Request(zone: .top, horizontal: .midpoint, vertical: .end),
                Request(zone: .right, horizontal: .midpoint, vertical: .end),
                Request(zone: .links, horizontal: .midpoint, vertical: .end),
            ]
        case .skipBack:
            [
                Request(zone: .links, horizontal: .midpoint, vertical: .midpoint),
                Request(zone: .topLeft, horizontal: .midpoint, vertical: .end),
                Request(zone: .bottomLeft, horizontal: .midpoint, vertical: .start),
            ]
        case .skipForward:
            [
                Request(zone: .right, horizontal: .midpoint, vertical: .midpoint),
                Request(zone: .topRight, horizontal: .midpoint, vertical: .end),
                Request(zone: .bottomRight, horizontal: .midpoint, vertical: .start),
            ]
        case .levelLeft:
            [
                Request(zone: .links, horizontal: .start, vertical: .midpoint),
                Request(zone: .topLeft, horizontal: .start, vertical: .end),
                Request(zone: .bottomLeft, horizontal: .start, vertical: .start),
            ]
        case .levelRight:
            [
                Request(zone: .right, horizontal: .end, vertical: .midpoint),
                Request(zone: .topRight, horizontal: .end, vertical: .end),
                Request(zone: .bottomRight, horizontal: .end, vertical: .start),
            ]
        }
    }

    /// The rectangle of a zone — `nil` if nothing fits there.
    ///
    /// **Inside means: between header and timeline, with distance to both.** The four sides of
    /// the transport row each cut a zone off it; the half zones above and below split at the
    /// middle of the row.
    static func rect(
        _ zone: Zone, in surface: CGRect, buttons: Buttons
    ) -> CGRect? {
        let a = spacing
        let links = surface.minX + a
        let right = surface.maxX - a
        let top = max(surface.minY, buttons.header.maxY) + a
        let bottom = min(surface.maxY, buttons.bar.minY) - a
        let row = buttons.transport
        switch zone {
        case .top: return frame(links, top, right, row.minY - a)
        case .bottom: return frame(links, row.maxY + a, right, bottom)
        case .links: return frame(links, top, row.minX - a, bottom)
        case .right: return frame(row.maxX + a, top, right, bottom)
        case .topLeft: return frame(links, top, row.midX - a / 2, row.minY - a)
        case .topRight: return frame(row.midX + a / 2, top, right, row.minY - a)
        case .bottomLeft: return frame(links, row.maxY + a, row.midX - a / 2, bottom)
        case .bottomRight: return frame(row.midX + a / 2, row.maxY + a, right, bottom)
        }
    }

    private static func frame(
        _ minX: CGFloat, _ minY: CGFloat, _ maxX: CGFloat, _ maxY: CGFloat
    ) -> CGRect? {
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Places all shown messages.
    ///
    /// - Parameters:
    ///   - gezeigt: What should be visible right now.
    ///   - flaeche: The whole control surface.
    ///   - knoepfe: The measured rows.
    ///   - messen: How large a message becomes at this proposal — the width wraps a sentence.
    ///     **An infinite height asks for the natural size**, a finite one for the most compact
    ///     that fits that height.
    /// - Returns: Per message its rectangle. **If one is missing, it has no place** — then it
    ///   stays away instead of falling onto a button or another message.
    static func slots(
        shown: Set<Feedback>, surface: CGRect, buttons: Buttons,
        measure: (Feedback, CGSize) -> CGSize
    ) -> [Feedback: CGRect] {
        var taken: [Feedback: CGRect] = [:]
        for report in Feedback.allCases where shown.contains(report) {
            let wishes = wishes(report).compactMap { request in
                rect(request.zone, in: surface, buttons: buttons).map { (request, $0) }
            }
            var queued: CGRect?
            for (request, zone) in wishes {
                let size = measure(report, natural(zone))
                guard matches(size, in: zone) else { continue }
                if let slot = create(
                    size, in: zone, request, row: buttons.transport,
                    beside: Array(taken.values))
                {
                    queued = slot
                    break
                }
            }
            if queued == nil {
                queued = fallback(
                    report, wishes: wishes, row: buttons.transport, taken: &taken,
                    measure: measure)
            }
            taken[report] = queued
        }
        return taken
    }

    /// No preference worked out — **the zones by size, measured compactly, next to the others.**
    ///
    /// Until 2026-09-25 the fallback placed with `beside: []`, i.e. without the messages
    /// already placed, and stacked them on top of each other (finding B2). Now: Whoever fits a
    /// zone when measured compactly and has room there next to the others, stands. Otherwise
    /// it displaces only **more fleeting** messages (``Feedback/volatility``); if that
    /// also fails, it stays away itself.
    private static func fallback(
        _ report: Feedback, wishes: [(Request, CGRect)], row: CGRect,
        taken: inout [Feedback: CGRect],
        measure: (Feedback, CGSize) -> CGSize
    ) -> CGRect? {
        let bySize = wishes.sorted {
            $0.1.width * $0.1.height > $1.1.width * $1.1.height
        }
        let moreStable = taken.filter { $0.key.volatility <= report.volatility }
        for beside in [Array(taken.values), Array(moreStable.values)] {
            for (request, zone) in bySize {
                let size = measure(report, suggestion(zone))
                guard matches(size, in: zone),
                    let slot = create(size, in: zone, request, row: row, beside: beside)
                else { continue }
                let displaced = taken.filter {
                    $0.key.volatility > report.volatility
                        && $0.value.intersects(slot.insetBy(dx: -spacing / 2, dy: -spacing / 2))
                }
                for kind in displaced.keys { taken[kind] = nil }
                return slot
            }
        }
        return nil
    }

    /// Whether a measured size fits into a rectangle — with half a point of rounding.
    static func matches(_ size: CGSize, in frame: CGRect) -> Bool {
        size.width <= frame.width + 0.5 && size.height <= frame.height + 0.5
    }

    /// The proposal for the natural size — the zone's width, the height open.
    private static func natural(_ zone: CGRect) -> CGSize {
        CGSize(width: min(zone.width, maxWidth), height: .infinity)
    }

    /// What a message is offered in this zone — the zone, at most ``maxWidth`` wide.
    private static func suggestion(_ zone: CGRect) -> CGSize {
        CGSize(width: min(zone.width, maxWidth), height: zone.height)
    }

    /// Puts a message at its anchor and moves it on if one already stands there.
    ///
    /// **At the start backward, at the end forward, in the middle not at all.** A message in
    /// the middle of a side strip would have two directions to yield in and none that would be
    /// more correct; it then takes its next preference.
    ///
    /// **The middle of a side strip is the height of the row**, not that of the strip: Header
    /// and bar are of different heights, and a jump next to +30 should stand next to +30 and
    /// not a few points above.
    private static func create(
        _ size: CGSize, in zone: CGRect, _ request: Request, row: CGRect,
        beside taken: [CGRect]
    ) -> CGRect? {
        let isSideways = request.zone == .links || request.zone == .right
        let midY = isSideways ? row.midY : zone.midY
        let x: CGFloat =
            switch request.horizontal {
            case .start: zone.minX
            case .midpoint: zone.midX - size.width / 2
            case .end: zone.maxX - size.width
            }
        var y: CGFloat =
            switch request.vertical {
            case .start: zone.minY
            case .midpoint:
                min(max(midY - size.height / 2, zone.minY), zone.maxY - size.height)
            case .end: zone.maxY - size.height
            }
        // Each step skips at least one occupied rectangle — after that many steps there is either
        // room or the zone is at its end.
        for _ in 0...taken.count {
            let slot = CGRect(origin: CGPoint(x: x, y: y), size: size)
            guard zone.insetBy(dx: -0.5, dy: -0.5).contains(slot) else { return nil }
            let im = taken.filter { $0.intersects(slot.insetBy(dx: -spacing / 2, dy: -spacing / 2)) }
            guard !im.isEmpty else { return slot }
            switch request.vertical {
            case .start: y = (im.map(\.maxY).max() ?? y) + spacing
            case .end: y = (im.map(\.minY).min() ?? y) - spacing - size.height
            case .midpoint: return nil
            }
        }
        return nil
    }
}
