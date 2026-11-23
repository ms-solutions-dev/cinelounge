import Core
import Foundation
import Observation

/// Holds the programme grid's window and fills it from the store.
///
/// **Window instead of world** (`design/konzept-p8.md`, section 3): The whole programme is
/// never loaded, only the visible period plus some lead in both
/// directions. With the database's indexes this is a
/// millisecond query — **the grid never talks to the network**.
///
/// **And it pages instead of scrolling freely.** Scrolling freely horizontally is a
/// test of patience with a remote without a wheel; a window that jumps on by an
/// hour is predictable and hits what the view is meant to
/// do: plan, not zap.
///
/// **Shared since 2026-09-26** (decision 27, B10): The iPad shows the same grid
/// with the same computation — window, step and lead apply on both devices. Only the
/// view stays per platform; on the iPhone there is no grid (393 pt).
@Observable
public final class GuideGridModel {

    /// How wide the window is.
    ///
    /// At 1920 points of screen width, two hours is the span in which an
    /// ordinary entry of 30 to 45 minutes still carries its title.
    public static let windowWidth: TimeInterval = 2 * 3600

    /// By how much a step advances — one hour, so that the edge of the
    /// old window reappears in the middle of the new one.
    public static let step: TimeInterval = 3600

    /// How far beyond the window loading goes.
    ///
    /// One window in each direction: That way everything is ready when paging on,
    /// and the jump costs no query.
    public static let leadTime: TimeInterval = windowWidth

    public private(set) var windowStart: Date
    public private(set) var rows: [ProgramGrid.Row] = []
    /// Whether anything has been loaded yet — before that, "no programme" is no
    /// information, just an empty start.
    public private(set) var isReady = false

    public var windowEnd: Date { windowStart.addingTimeInterval(Self.windowWidth) }

    private var channelList: [Channel] = []
    private let load: @Sendable ([Channel], Date, Date) async -> [String: [Programme]]
    /// What was loaded last — including the span, so that a step within the
    /// lead triggers no new query.
    private var downloads: [String: [Programme]] = [:]
    private var bufferedFrom: Date = .distantFuture
    private var bufferedUntil: Date = .distantPast
    /// The running query.
    ///
    /// Readable within the package so that the checks can await it instead of
    /// sleeping — the same construction as with the engine start in the player. A `yield`
    /// is not enough for that: It is not a meeting point, only a request.
    public private(set) var running: Task<Void, Never>?

    public init(
        now: Date = Date(),
        load: @escaping @Sendable ([Channel], Date, Date) async -> [String: [Programme]]
    ) {
        self.windowStart = Self.gridStart(now)
        self.load = load
    }

    /// The start of the window, placed on the half hour before.
    ///
    /// **Not on "now"**: Otherwise the view would begin in the middle of the
    /// running programme, and its start — the title — would lie off to the left.
    public static func gridStart(_ now: Date) -> Date {
        let half: TimeInterval = 1800
        let slots = (now.timeIntervalSince1970 / half).rounded(.down)
        return Date(timeIntervalSince1970: slots * half)
    }

    /// Sets the channels of the selected group and reloads.
    public func show(_ channels: [Channel], now: Date = Date()) {
        channelList = channels
        bufferedFrom = .distantFuture
        bufferedUntil = .distantPast
        refresh(now: now)
    }

    /// Pages forward or back.
    public func page(_ direction: Direction, now: Date = Date()) {
        windowStart = windowStart.addingTimeInterval(
            direction == .forward ? Self.step : -Self.step)
        refresh(now: now)
    }

    public enum Direction: Sendable { case back, forward }

    /// Jumps back to the current hour.
    public func backToNow(now: Date = Date()) {
        windowStart = Self.gridStart(now)
        refresh(now: now)
    }

    /// Whether the window contains the current time at all.
    public func showsNow(_ now: Date) -> Bool {
        now >= windowStart && now < windowEnd
    }

    /// Recomputes the rows — and fetches only what the store does not cover.
    public func refresh(now: Date = Date()) {
        let from = windowStart
        let until = windowEnd

        // The store covers the window: compute immediately, no query.
        if from >= bufferedFrom, until <= bufferedUntil {
            rows = ProgramGrid.rows(
                channels: channelList, programs: downloads, from: from, until: until, now: now)
            isReady = true
            return
        }

        let fetchFrom = from.addingTimeInterval(-Self.leadTime)
        let fetchUntil = until.addingTimeInterval(Self.leadTime)
        let channels = channelList
        running?.cancel()
        running = Task { [weak self, load] in
            let fresh = await load(channels, fetchFrom, fetchUntil)
            guard !Task.isCancelled, let self else { return }
            self.downloads = fresh
            self.bufferedFrom = fetchFrom
            self.bufferedUntil = fetchUntil
            self.rows = ProgramGrid.rows(
                channels: channels, programs: fresh, from: from, until: until, now: now)
            self.isReady = true
        }
    }

    public func stop() {
        running?.cancel()
        running = nil
    }
}
