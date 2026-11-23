import Foundation

/// What a provider has learned about **its kind** of channel: playlist or raw stream.
///
/// **The finding** (AP3 · V5, expert review 2026-08-24): "Every unknown channel starts twice."
/// The memo ``RawStreamMemory`` remembers **addresses** — so it can help only once a
/// channel has already stayed blind. In the test run it grew from 104 to 155 channels:
/// 51 times eight seconds of black, 51 surplus connections against an account with **one**
/// connection slot.
///
/// **Why not simply "this provider cannot do HLS".** Because it is not true: With the
/// provider examined, the H.264 channels play as a playlist, and only the 4K and HEVC
/// versions stay black. One rule per provider would send the carrying channels through the
/// second engine for no reason — it would lose the system bar for an error that does not
/// exist there.
///
/// **So per provider *and* feature.** The feature is in the name because the provider
/// writes it there: `ᵁᴴᴰ`, `4K`, `HEVC`. A pair of counterpart and feature is learned, and
/// it is asked before the first attempt — that is the whole difference from the memo.
///
/// **Both count, success as well as failure.** A counter that collects only failures says
/// "always raw" after the first one — and would be permanently wrong for the H.264
/// channels. Only the ratio supports a prediction, and only from a number of observations
/// that is no longer chance.
public struct RawStreamRule: Sendable, Equatable {

    /// **Version 2 since 2026-10-04** (F-033): Until then the player counted a startup as a
    /// success of the playlist already if only the audio played — the old states are therefore
    /// half "playlist" where there was none, and would never get over the threshold. Starting
    /// over is cheaper: the per-channel memo (``RawStreamMemory``) stays, and after four
    /// fallbacks the rule stands again.
    static let key = "live.rawStreamRule.v2"
    /// The key of the old count — cleared away on the first save.
    static let oldKey = "live.rawStreamRule"

    /// From how many observations of a pair a prediction is made at all.
    ///
    /// Four: a single blind channel is a channel, not a kind. With four identical
    /// observations, the next one with the same feature is the likelier bet than another blind
    /// attempt.
    public static let minimumObservations = 4

    /// How unambiguous it has to be — four out of five.
    ///
    /// Not "all": A single outlier — a channel that failed once for another reason — would
    /// otherwise disable the rule for good.
    public static let shareNumerator = 4
    public static let shareDenominator = 5

    /// How many pairs are remembered at most. A provider has a handful of features; the limit
    /// catches the case that a name contains something that looks like a feature.
    static let atMost = 60

    /// A pair of counters: how often the raw stream was needed, how often not.
    public struct State: Sendable, Equatable {
        public var raw: Int
        public var list: Int

        public init(raw: Int = 0, list: Int = 0) {
            self.raw = raw
            self.list = list
        }

        public var observations: Int { raw + list }
    }

    private var progressStates: [String: State]

    public init(progressStates: [String: State] = [:]) {
        self.progressStates = progressStates
    }

    // MARK: - Das Paar

    /// The counterpart and the feature of a channel — the key.
    ///
    /// The **counterpart** and not the identifier of the channel list: the provider is the
    /// machine that answers, and the same counterpart under two lists delivers the same
    /// streams. It is also in the playback target — the list identifier is not, and a state
    /// you first have to pass along gets forgotten somewhere.
    public static func pair(counterpart: String?, name: String) -> String {
        (counterpart ?? "-") + "#" + trait(name)
    }

    /// The feature of a channel name — the strongest word it names.
    ///
    /// The same words as in ``ChannelVariants/quality(_:)``, and for the same reason: The
    /// provider writes the version into the name so that one can choose. If it names nothing,
    /// that is also a feature — the unlabelled version is the most common, and it is the one
    /// that holds.
    public static func trait(_ name: String) -> String {
        let words = Set(ChannelName.searchKey(name).split(separator: " ").map(String.init))
        for candidate in ["8K", "4K", "UHD", "2160P", "3840P", "HEVC", "H265", "X265"]
        where words.contains(candidate) {
            // 4K and UHD are the same promise, HEVC is the reason behind it — splitting them into
            // three buckets would mean learning three times as long as necessary.
            return candidate == "HEVC" || candidate == "H265" || candidate == "X265" ? "HEVC" : "UHD"
        }
        for candidate in ["FHD", "1080P", "1080I"] where words.contains(candidate) { return "FHD" }
        for candidate in ["HD", "720P"] where words.contains(candidate) { return "HD" }
        return "-"
    }

    // MARK: - Fragen

    /// Whether the raw stream is to be predicted for this pair.
    public func saysRaw(_ pair: String) -> Bool {
        guard let state = progressStates[pair], state.observations >= Self.minimumObservations
        else { return false }
        return state.raw * Self.shareDenominator >= state.observations * Self.shareNumerator
    }

    public func state(_ pair: String) -> State { progressStates[pair] ?? State() }

    /// How many pairs have been learned — for the trace.
    public var count: Int { progressStates.count }

    // MARK: - Lernen

    /// The raw stream was needed: the playlist carried no picture.
    public mutating func rememberRaw(_ pair: String) {
        var state = progressStates[pair] ?? State()
        state.raw += 1
        set(pair, state)
    }

    /// The playlist carried — **or the raw stream did not**.
    ///
    /// Both are the same statement about the prediction: "for this kind, the raw stream is not
    /// the way". Without the second case a rule that has become wrong would stand forever —
    /// the provider switches over, and the app would keep sending every channel of this kind
    /// onto a dead stream.
    public mutating func rememberList(_ pair: String) {
        var state = progressStates[pair] ?? State()
        state.list += 1
        set(pair, state)
    }

    private mutating func set(_ pair: String, _ state: State) {
        progressStates[pair] = state
        guard progressStates.count > Self.atMost else { return }
        // The pair with the fewest observations is evicted — it is the one that says the least.
        // On a tie the key decides, so the same store always has the same result.
        //
        // **Never the one just written**, even if it is the poorest: Otherwise a full store could
        // learn nothing new, and the rule would freeze at the state of the day it became full.
        let sparsest = progressStates.filter { $0.key != pair }.min {
            $0.value.observations == $1.value.observations
                ? $0.key < $1.key : $0.value.observations < $1.value.observations
        }
        if let sparsest { progressStates.removeValue(forKey: sparsest.key) }
    }

    // MARK: - Store

    /// Line-separated like the other lists of this app, fields separated by tab: Neither
    /// occurs in a counterpart or in a feature.
    public static func load(from store: any KeyValueStore) -> RawStreamRule {
        let raw = (try? store.value(for: key)) ?? ""
        var progressStates: [String: State] = [:]
        for row in raw.split(separator: "\n") {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, let a = Int(fields[1]), let b = Int(fields[2]) else { continue }
            progressStates[String(fields[0])] = State(raw: a, list: b)
        }
        return RawStreamRule(progressStates: progressStates)
    }

    public func save(to store: any KeyValueStore) {
        try? store.remove(Self.oldKey)
        guard !progressStates.isEmpty else {
            try? store.remove(Self.key)
            return
        }
        // Sorted, so the same knowledge always yields the same line — otherwise a comparison sees
        // changes where there are none.
        let rows = progressStates.sorted { $0.key < $1.key }
            .map { "\($0.key)\t\($0.value.raw)\t\($0.value.list)" }
        try? store.set(rows.joined(separator: "\n"), for: Self.key)
    }
}
