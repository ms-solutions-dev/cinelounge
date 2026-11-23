import Foundation

/// The entry of a PIN — **digit count, repetition, comparison and shuffled order in one
/// place** (AP58 R2, finding P2).
///
/// **The finding:** TV and phone each rebuilt the flow in their sheet. The phone ran the
/// stages "check → new → repeat" in the `PinSheet`, the TV the same repetition in
/// `PinSetSheet` with a trick (the first entry "doesn't match" so that the sheet stays
/// up); shuffling happened only on the TV. What remains per device is the keypad itself â
/// focus grid or touch.
///
/// **A value and not a view**, so that the rules can be checked without a screen: the fourth
/// digit submits, a differing repetition starts over (repeating only the second would mean
/// making people guess which one was meant), and after every failed attempt the layout is a
/// different one.
///
/// **No counter and no lock after three attempts** — justification at the sheets: four
/// digits are 10,000 possibilities, and a waiting lock would hit first the parent who
/// mistypes in the dark.
public struct PinEntry: Sendable, Equatable {

    /// Where the entry currently is.
    public enum Tier: Sendable, Equatable {
        /// An existing PIN.
        case verify
        /// Assign a new one.
        case fresh
        /// And repeat it.
        case repeatEntry
    }

    /// What a complete entry has caused.
    public enum Outcome: Sendable, Equatable {
        /// Checked and correct — the digits go along, for instance as proof for changing.
        case verified(String)
        /// Checked and wrong. The entry is empty, the layout new.
        case wrong
        /// The new one is remembered; now the repetition.
        case repeatEntry
        /// The repetition differed — back to the new one, from the start.
        case deviation
        /// Twice the same: this PIN is to be set.
        case chosen(String)
    }

    /// How many digits — ``Pin/locations``, the same number for device and profile PIN.
    public static let locations = Pin.locations

    /// **Whether this device shuffles the keys.**
    ///
    /// **On the TV yes, on the phone no — deliberately** (AP58 R2). A number pad in row form
    /// can be read **from the hand movement** on 55 inches from two metres away: whoever knows
    /// the layout reads the PIN from the direction of the thumb on the remote. On the phone the
    /// pad lies under the hand, the layout is the system's (as when unlocking), and a shuffled
    /// one would mainly be a pad you have to scan anew every time. The decision stands here as a
    /// value and not as a silent gap in one of the sheets.
    public static var shufflesOnDevice: Bool {
        #if os(tvOS)
            true
        #else
            false
        #endif
    }

    public private(set) var tier: Tier
    /// What has been typed so far — never more than ``locations``.
    public private(set) var digits = ""
    /// The layout of the ten keys, **rolled once per sheet** and anew after every failed attempt.
    /// Without shuffling `0…9`.
    public private(set) var keys: [Int]
    public let shuffles: Bool
    private var remembered: String?

    /// - Parameters:
    ///   - beginn: ``Tier/verify`` for an existing PIN, ``Tier/fresh`` for assigning.
    ///   - tasten: for tests only — a fixed layout.
    public init(start: Tier, shuffles: Bool = PinEntry.shufflesOnDevice, keys: [Int]? = nil) {
        self.tier = start
        self.shuffles = shuffles
        self.keys = keys ?? (shuffles ? Array(0...9).shuffled() : Array(0...9))
    }

    /// Whether all digits have been typed.
    public var full: Bool { digits.count == Self.locations }

    /// Adds a digit — **the fourth one submits**: the whole entry then comes back, which the
    /// caller hands to ``take(_:verify:)``. An "OK" afterwards would be a press whose answer is
    /// already settled.
    public mutating func tap(_ digit: Int) -> String? {
        guard !full, (0...9).contains(digit) else { return nil }
        digits.append(String(digit))
        return full ? digits : nil
    }

    public mutating func deleteLast() {
        guard !digits.isEmpty else { return }
        digits.removeLast()
    }

    /// Takes a complete entry — **and always clears afterwards.** Whoever stands here after a
    /// failed attempt wants to try again immediately and not clear something away first.
    ///
    /// - Parameter pruefe: only for ``Tier/verify`` — whether the digits are the PIN.
    public mutating func take(_ input: String, verify: (String) -> Bool) -> Outcome {
        digits = ""
        switch tier {
        case .verify:
            guard verify(input) else {
                reshuffle()
                return .wrong
            }
            return .verified(input)
        case .fresh:
            remembered = input
            tier = .repeatEntry
            return .repeatEntry
        case .repeatEntry:
            guard input == remembered else {
                remembered = nil
                tier = .fresh
                reshuffle()
                return .deviation
            }
            return .chosen(input)
        }
    }

    /// After the checked old PIN on to the new one — **the path when changing.**
    public mutating func continueToNew() {
        digits = ""
        remembered = nil
        tier = .fresh
    }

    /// **Reshuffle after a failed attempt.** Whoever has watched has seen one layout; on the
    /// second attempt it should be worth nothing any more.
    public mutating func reshuffle() {
        guard shuffles else { return }
        keys.shuffle()
    }
}
