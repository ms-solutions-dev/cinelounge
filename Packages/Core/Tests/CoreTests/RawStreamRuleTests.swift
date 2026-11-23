import Foundation
import Testing

@testable import Core

/// The learned rule "which kind of channel goes raw" — AP3 · V5.
///
/// **The finding:** "Every unknown channel starts twice." The memo list
/// ``RawStreamMemory`` remembers addresses and can therefore only help once a channel
/// has already gone blind; in the test run it grew from 104 to 155 channels. This
/// rule remembers the **kind** — counterpart and trait — and is asked before the
/// first attempt.
@Suite("The raw-stream rule")
struct RawStreamRuleTests {

    typealias Memory = InMemoryStore

    static let provider = "gold.example"

    static func pair(_ name: String, counterpart: String = provider) -> String {
        RawStreamRule.pair(counterpart: counterpart, name: name)
    }

    // MARK: - Das Merkmal

    /// **The variant is in the name because the provider writes it there.** 4K and UHD
    /// are the same promise; separating them into two pots would mean learning twice as
    /// long as necessary.
    @Test("The trait is the strongest word of the name")
    func trait() {
        #expect(RawStreamRule.trait("KIES: NERGIS ᵁᴴᴰ 3840P") == "UHD")
        #expect(RawStreamRule.trait("KIES: NERGIS 4K") == "UHD")
        #expect(RawStreamRule.trait("KIES: NERGIS HEVC") == "HEVC")
        #expect(RawStreamRule.trait("KIES: NERGIS ᶠᴴᴰ") == "FHD")
        #expect(RawStreamRule.trait("KIES: NERGIS ᴴᴰ") == "HD")
        // "Nothing" is also a trait: the undescribed variant is the most common, and it is
        // the one that works.
        #expect(RawStreamRule.trait("KIES: NERGIS RAW") == "-")
    }

    /// **Two kinds of the same provider are two pairs.** That is the reason why there is
    /// no rule per provider: with the tested one, the H.264 channels play as a playlist,
    /// and only the 4K variants stay black.
    @Test("Provider and trait together make the key")
    func pairSeparatesKinds() {
        #expect(Self.pair("NERGIS ᵁᴴᴰ") != Self.pair("NERGIS ᴴᴰ"))
        #expect(Self.pair("NERGIS ᵁᴴᴰ") != Self.pair("NERGIS ᵁᴴᴰ", counterpart: "silber.example"))
        // Two channels of the same kind are the same pair — otherwise nothing would be
        // learned, only counted.
        #expect(Self.pair("NERGIS ᵁᴴᴰ") == Self.pair("TELVE 1 ᵁᴴᴰ"))
    }

    // MARK: - Die Vorhersage

    /// **A single blind channel is a channel, not a kind.** Without this threshold the
    /// first observation would immediately send every channel of the same trait through
    /// the second engine.
    @Test("Nothing is predicted below four observations")
    func threshold() {
        var rule = RawStreamRule()
        let pair = Self.pair("NERGIS ᵁᴴᴰ")
        for _ in 1...3 { rule.rememberRaw(pair) }

        #expect(!rule.saysRaw(pair))

        rule.rememberRaw(pair)
        #expect(rule.saysRaw(pair))
    }

    /// Four out of five suffice: a single outlier — a channel that failed once for
    /// another reason — must not shut the rule down.
    @Test("Four out of five suffice, three out of five do not")
    func portion() {
        var rule = RawStreamRule()
        let pair = Self.pair("NERGIS ᵁᴴᴰ")
        for _ in 1...4 { rule.rememberRaw(pair) }
        rule.rememberList(pair)
        #expect(rule.saysRaw(pair))

        var tight = RawStreamRule()
        for _ in 1...3 { tight.rememberRaw(pair) }
        for _ in 1...2 { tight.rememberList(pair) }
        #expect(!tight.saysRaw(pair))
    }

    /// **The working channels stay on the playlist.** This is the control case to the
    /// whole rule: a prediction that also applies to the H.264 channels would lose the
    /// system bar for an error that does not exist there.
    @Test("What holds up is not redirected")
    func carryingRemain() {
        var rule = RawStreamRule()
        let uhd = Self.pair("NERGIS ᵁᴴᴰ")
        let hd = Self.pair("NERGIS ᴴᴰ")
        for _ in 1...5 { rule.rememberRaw(uhd) }
        for _ in 1...5 { rule.rememberList(hd) }

        #expect(rule.saysRaw(uhd))
        #expect(!rule.saysRaw(hd))
    }

    /// **The rule can heal.** The provider switches over, and without the counter-
    /// evidence the app would send every channel of this kind to a dead stream — the same
    /// trap as with the memo list on 2026-08-15. (Telve 1 HEVC).
    @Test("A dead raw stream takes the prediction back")
    func ruleHeals() {
        var rule = RawStreamRule()
        let pair = Self.pair("NERGIS ᵁᴴᴰ")
        for _ in 1...4 { rule.rememberRaw(pair) }
        #expect(rule.saysRaw(pair))

        // Four counter-evidences: 4 raw against 4 list is half, and half predicts nothing.
        for _ in 1...4 { rule.rememberList(pair) }
        #expect(!rule.saysRaw(pair))
    }

    // MARK: - Die Ablage

    @Test("The rule survives the store")
    func store() {
        let store = Memory()
        var rule = RawStreamRule()
        let pair = Self.pair("NERGIS ᵁᴴᴰ")
        for _ in 1...4 { rule.rememberRaw(pair) }
        rule.rememberList(Self.pair("NERGIS ᴴᴰ"))
        rule.save(to: store)

        let read = RawStreamRule.load(from: store)

        #expect(read.saysRaw(pair))
        #expect(read.state(pair) == RawStreamRule.State(raw: 4, list: 0))
        #expect(read.state(Self.pair("NERGIS ᴴᴰ")) == RawStreamRule.State(raw: 0, list: 1))
    }

    /// An empty rule leaves no line behind — and an empty store predicts nothing instead
    /// of guessing.
    @Test("Nothing is predicted without knowledge")
    func empty() {
        #expect(!RawStreamRule.load(from: Memory()).saysRaw(Self.pair("NERGIS ᵁᴴᴰ")))
    }

    /// The limit catches the case that a name contains something that looks like a trait
    /// — and it throws away the pair that says the least.
    ///
    /// **Never the one just written**, even if it is the poorest: otherwise a full store
    /// could never learn anything new.
    @Test("The limit hits the poorest pair, not the new one")
    func limit() {
        var rule = RawStreamRule()
        for number in 1...RawStreamRule.atMost {
            let pair = "provider\(number)#UHD"
            // One says less than all the others — it is the one that goes.
            for _ in 1...(number == 7 ? 1 : 3) { rule.rememberRaw(pair) }
        }

        rule.rememberRaw("new#UHD")

        #expect(rule.count == RawStreamRule.atMost)
        #expect(rule.state("provider7#UHD").observations == 0)
        #expect(rule.state("new#UHD").raw == 1)
        #expect(rule.state("provider1#UHD").raw == 3)
    }
}
