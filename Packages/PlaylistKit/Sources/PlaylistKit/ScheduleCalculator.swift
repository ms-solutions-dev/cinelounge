import Core
import Foundation

/// Computes the schedule — **outside ``LiveLibrary``, and at most
/// once per state of the cache**.
///
/// **Two findings from stage 5 of the sports concept, one component.**
///
/// *First: The computation sat in the wrong actor.* `sportEvents(from:to:)`
/// ran in the body of ``LiveLibrary``. An actor handles one request after
/// the other — as long as the pattern matching ran (measured at device size
/// 3.4 s, before E5 7.4 s), **nobody else** got an answer: not the
/// channel list, which needs its "what is on now" for every row, not the
/// channel search, not the jump into the player. The area did not feel
/// slow, but dead, and precisely wherever you were not at
/// all. The computation itself does not need ``LiveLibrary``; it needs
/// only its ingredients. So it fetches them, releases the actor and computes on
/// an ordinary thread (``Task/detached(priority:operation:)``).
///
/// *Second: It ran from scratch every time.* Switching a tab back and forth
/// computed the same thing twice, although nothing had changed in between.
/// The result store therefore hangs off the pair that determines the answer:
/// **day window and cache state**. If neither the window nor the
/// number of stored programs nor their reach changes, the answer cannot be
/// different — the first pass stays expensive, every further one is free.
///
/// **What is NOT in the key is discarded by hand.** The fixtures of the
/// online source change without a program being added; ``clear()``
/// is therefore tied to ``LiveLibrary/syncFixtures(from:)`` and ``LiveLibrary/invalidate()``.
/// A store that conceals such a change would be
/// worse than none: it would show the old schedule and nobody would know
/// why.
actor ScheduleCalculator {

    /// Everything the computation needs from the cache — and nothing else.
    struct Ingredients: Sendable {
        let broadcasts: [Programme]
        /// Display name per guide identifier — for sport recognition.
        let channelNames: [String: String]
        let fixtures: [SportFixture]
        /// **All** channels, no longer only those without a guide identifier (E7).
        ///
        /// Until E6 only the nameless ones arrived here, because only the
        /// League Pass stage needed a channel list. Since E7 the
        /// channel board asks for them too: "DE: ARENA BUNDESLIGA 1 HD" carries its
        /// competition in the name and does have a guide identifier — it
        /// just names nothing but "BL".
        let channels: [SportChannel]
        /// The stored observations of the live board.
        let observations: [ChannelCompetition]
        /// Today's broadcast schedule, if a source knows it.
        ///
        /// With a default, because it plays no role for most tests —
        /// and because a missing source means exactly that: no information,
        /// not "no broadcast".
        var broadcastPlan: [SportBroadcastPlan.BroadcastSlot] = []
    }

    /// What decides whether a stored answer still applies.
    ///
    /// The reach (`newest`) stands next to the count because the two can
    /// change independently: `pruneProgrammes()` clears away the past —
    /// the count drops, the reach stays — and a sync pushes the
    /// reach forward without the count having to reveal it.
    ///
    /// And the sync switch: whoever flips it under settings
    /// gets a different list from the same cache.
    struct Key: Hashable, Sendable {
        let from: Date
        let end: Date
        let broadcasts: Int
        let newest: Date?
        let syncEnabled: Bool

        /// **The version of the computation rules.**
        ///
        /// Since the schedule survives on disk (version 7), it also survives
        /// a new version of the app — and that is not good news: if a rule changes
        /// without window, count or reach of the cache moving, the old answer
        /// is still delivered. On the evening of 2026-08-29 exactly that was in question ("my sports area
        /// somehow does not update"); there it was a different
        /// bug, but the trap is real and closing it costs nothing.
        ///
        /// **Increment whenever something changes in the computation** — in
        /// ``calculate(_:)`` or in what it calls.
        static let ruleState = 2

        /// The same key as a string — for storage on disk.
        ///
        /// To-the-second and without separators that can occur in a number:
        /// two different keys must never get the same identifier,
        /// otherwise the app would show the schedule of another day.
        var identifier: String {
            [
                String(Int(from.timeIntervalSince1970)),
                String(Int(end.timeIntervalSince1970)),
                String(broadcasts),
                newest.map { String(Int($0.timeIntervalSince1970)) } ?? "-",
                syncEnabled ? "1" : "0",
                "r\(Key.ruleState)",
            ].joined(separator: "#")
        }
    }

    /// How many answers are kept.
    ///
    /// Four. The number comes from the day tabs (three at most, plus one
    /// reserve for the change of cache state) and stays so even without them:
    /// the window rolls with the clock, and every minute is a new
    /// key — four answers are the stock for refreshing several times in
    /// quick succession. More would be memory for a window that no longer
    /// exists; an answer is a list of events with all their
    /// identifiers.
    static let atMost = 4

    private var stored: [Key: [SportEvent]] = [:]
    /// The order of storing — the oldest goes first.
    private var order: [Key] = []
    /// Running computations, **as an operation and not as a result**. Same
    /// reasoning as with ``LiveLibrary``: whoever asks the same thing while a
    /// computation is running attaches to it instead of kicking off a second one.
    private var running: [Key: Task<[SportEvent], Never>] = [:]
    /// How often it was cleared.
    ///
    /// **Acceptance 2026-08-29: Clearing during a running computation was
    /// ineffective.** ``clear()`` cleared only what was stored, and the computation
    /// already running alongside stored its answer afterwards anyway — from
    /// ingredients from before the clearing. That would have hit exactly the case for which
    /// ``clear()`` exists at all: the one the key does not notice. Whoever
    /// presses refresh in the open area while the first pass
    /// is still computing, and gets the same guide back with corrected titles,
    /// moves neither count nor reach — the key
    /// would stay the same, and the answer just discarded would be back afterwards.
    ///
    /// A finished computation therefore compares the state that applied when it was kicked off
    /// with today's. If they differ, it still hands its answer
    /// to its own caller — whose load is canceled anyway
    /// and throws it away —, but does not store it.
    private var clearings = 0

    /// The events for a state — from the store or freshly computed.
    ///
    /// - Parameter zutaten: Called **only on a miss**. That is
    ///   the point: a hit fetches neither the channel list nor the
    ///   guide, and nothing is computed at all.
    ///
    /// **What a hit costs anyway**, so that the number does not look
    /// better than it is: the caller first has to form the key, and
    /// for that needs the cache state (one query: count, oldest and
    /// newest start in one pass) and the sync switch (one trip
    /// to the Keychain). Measured, that is the
    /// 1.7 ms of the second pass in ``ScheduleTimingTests`` — versus
    /// 5.1 s without the store.
    func events(
        _ key: Key,
        ingredients: @escaping @Sendable () async -> Ingredients
    ) async -> [SportEvent] {
        if let done = stored[key] { return done }
        if let isRunning = running[key] { return await isRunning.value }

        // `detached` and not `Task { }`: an ordinary task inherits the
        // isolation of its creator and would thus run on exactly the actor
        // this computation is meant to keep free.
        let operation = Task.detached(priority: .userInitiated) {
            Self.calculate(await ingredients())
        }
        let startedAt = clearings
        running[key] = operation
        let result = await operation.value
        // If cleared in the meantime, this answer no longer applies: it was
        // computed from ingredients from before. Reasoning at ``clearings``.
        guard startedAt == clearings else { return result }
        running[key] = nil
        create(result, under: key)
        return result
    }

    /// Discards all stored answers. See the reasoning above: what is
    /// not in the key has to be discarded by hand.
    func clear() {
        stored.removeAll()
        order.removeAll()
        // **The running ones too.** Whoever attaches to a computation that began before
        // the clearing would get exactly the answer that was just
        // discarded — only without it ever having been stored.
        running.removeAll()
        clearings += 1
    }

    private func create(_ events: [SportEvent], under key: Key) {
        if stored[key] == nil { order.append(key) }
        stored[key] = events
        while order.count > Self.atMost {
            stored.removeValue(forKey: order.removeFirst())
        }
    }

    /// The computation itself — pure, clock-free and without an actor.
    ///
    /// `nonisolated`, so that it runs where it is called: on the
    /// detached thread. Everything that is here used to be in the body of
    /// ``LiveLibrary/sportEvents(from:to:)`` — the rules are unchanged,
    /// only the place is different.
    nonisolated static func calculate(_ ingredients: Ingredients) -> [SportEvent] {
        let guess = SportPlan.events(
            from: ingredients.broadcasts, channelNames: ingredients.channelNames)

        // The reconciliation on top: fixtures of the online source against the same
        // guide — evidence beats guess, the rest stays a supplement.
        // If it is switched off, no fixtures come in at all, and the
        // computation stays with the guess.
        guard !ingredients.fixtures.isEmpty else { return guess }

        let taken = SportMatch.events(
            fixtures: ingredients.fixtures,
            programmes: ingredients.broadcasts,
            channels: ingredients.channels,
            board: board(ingredients),
            broadcastPlan: ingredients.broadcastPlan)
        return SportMatch.combined(
            verified: taken, heuristic: guess, fixtures: ingredients.fixtures)
    }

    /// The live board for this computation.
    ///
    /// Two origins are assembled here: the **stored**
    /// observations and the assignments **from the channel names**. The latter
    /// arise anew with every computation — from the channel list and the
    /// vocabulary that the fixtures in the cache bring along. Precisely for that reason they do not
    /// age: if the provider changes, the channel names change, and the
    /// vocabulary keeps coming from the same source (addendum of 2026-08-29).
    nonisolated static func board(_ ingredients: Ingredients) -> SportChannelBoard {
        let vocabulary = SportChannelBoard.vocabulary(ingredients.fixtures)
        var fromNames: [String: Set<String>] = [:]
        for channels in ingredients.channels {
            let flattened = SportKind.normalized(channels.name)
            for (path, words) in vocabulary {
                for word in words where SportCompetition.carries(SportKind.normalized(word), flattened) {
                    fromNames[channels.key, default: []].insert(path)
                }
            }
        }
        return SportChannelBoard(observations: ingredients.observations, fromNames: fromNames)
    }
}
