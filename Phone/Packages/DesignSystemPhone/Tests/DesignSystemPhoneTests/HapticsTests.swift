import Foundation
import Testing

@testable import DesignSystemPhone

/// The feedback switch — **the only place on ``Haptics`` that can be tested.**
///
/// Whether a tap reaches the device is decided by iOS; that cannot be recomputed here and is
/// not meant to be — exactly why this app uses `sensoryFeedback` and not its own generator.
/// What is testable is the one rule the app sets itself: **whoever has set nothing gets
/// feedback.** An inverted default would be invisible on screen — the app would simply be
/// silent, and nobody would think a missing entry was to blame.
/// **`.serialized`, because all tests touch the same entry.** Swift Testing otherwise runs
/// them side by side: one sets `false`, the next reads, and both are right. Seen exactly so
/// on 2026-09-07 — "Explicitly switched on is on" failed while its two neighbors passed.
@Suite("Haptics", .serialized)
struct HapticsTests {

    /// **The entry is reset around the test.** `UserDefaults.standard` survives the process; a
    /// test that leaves it lying decides the next one.
    private func withStore(_ value: Bool?, _ verify: () -> Void) {
        let store = UserDefaults.standard
        let previous = store.object(forKey: Haptics.storeKey)
        defer { store.set(previous, forKey: Haptics.storeKey) }
        store.set(value, forKey: Haptics.storeKey)
        verify()
    }

    @Test("Without an entry the feedback is on")
    func preset() {
        withStore(nil) { #expect(Haptics.isOn) }
    }

    @Test("Switched off stays off")
    func off() {
        withStore(false) { #expect(!Haptics.isOn) }
    }

    /// The explicitly set true case belongs too: it distinguishes "on because set" from "on
    /// because nothing is there" — and only so is it noticed if someone later swaps the query for
    /// a `bool(forKey:)` that flattens both cases.
    @Test("Explicitly switched on is on")
    func on() {
        withStore(true) { #expect(Haptics.isOn) }
    }

    /// **The key is part of the contract.** Area 6 writes it, this file reads it; whoever renames
    /// it here switches off the user's setting without anything failing.
    @Test("The storage key is fixed")
    func storeKey() {
        #expect(Haptics.storeKey == "app.haptics")
    }
}
