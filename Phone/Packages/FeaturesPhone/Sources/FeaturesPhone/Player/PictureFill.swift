import Core
import Foundation
import Playback

// **``ImageLayout`` lives in `Playback` and not here.** It describes how a layer
// places its picture — that is a matter for the engine and not this memory. Here stands only what
// the viewer wanted last.

/// What the viewer wanted last — **per aspect ratio and not per title.**
///
/// **That is the whole reasoning of this type.** Whoever fills a 21:9 film wants that for
/// every 21:9 film; asking per title would be the same question in series. A global
/// memory, by contrast, would be dangerous: it would afterwards also crop a 4:3 home video,
/// and at the side where the faces are. This very concern fixed
/// `.resizeAspect` on the TV (`VideoSurface.swift`) — here it is not
/// ignored but built in.
///
/// **It is rounded to one decimal place**, and that is no convenience: 2.35 and
/// 2.39 are two spellings of the same cinema format. Making two compartments of them would mean
/// demanding the same decision twice — at the next film it would look as if
/// the app had forgotten.
extension ImageLayout {
    /// The catalog key for the overlay after switching.
    ///
    /// **Not in `Playback`**: there is no language catalog there, and on the TV
    /// the state is never named, because it never changes there.
    var label: String {
        self == .fullImage ? "player.fit" : "player.fill"
    }
}

@MainActor
public final class PictureFill {

    public static let shared = PictureFill()

    /// **On disk and since 2026-09-21 in ``Core/FileStore``** (AP40): What the
    /// viewer has set per format is structure.
    private let store: any KeyValueStore
    /// **No dot in the name, and that is not taste.** `scripts/strings.py` treats
    /// every string of the form `word.word` as a catalog key and reported
    /// "player.bildlage is missing from the catalog" — rightly, because one cannot tell from a
    /// string what it is for. A store key is therefore named here like
    /// a property and not like a sentence.
    static let key = "bildlageJeFormat"

    /// Testable with a store of its own — the default writes into the program's.
    public init(store: (any KeyValueStore)? = nil) {
        self.store = store ?? FileStore()
    }

    /// The state for an aspect ratio. Without a memory: ``ImageLayout/fullImage``.
    ///
    /// **The default is never "filling", not even after a hundred filled films of
    /// another format.** An unknown format is not worth a guess: the damage
    /// of an unnecessary bar is a bar, the damage of an unnecessary crop is
    /// a missing part of the picture that nobody misses because they never saw it.
    public func state(forItem ratio: Double) -> ImageLayout {
        guard let bucket = Self.bucket(ratio) else { return .fullImage }
        return board[bucket].flatMap(ImageLayout.init(rawValue:)) ?? .fullImage
    }

    public func set(_ state: ImageLayout, forItem ratio: Double) {
        guard let bucket = Self.bucket(ratio) else { return }
        var remembered = board
        // **The default is deleted and not written.** Otherwise the store would grow by
        // every format that someone watched once and set back — and
        // "nothing remembered" could no longer be distinguished from "explicitly whole picture".
        if state == .fullImage {
            remembered.removeValue(forKey: bucket)
        } else {
            remembered[bucket] = state.rawValue
        }
        if remembered.isEmpty {
            RecordSheet.cleanUp(Self.key, in: store)
        } else {
            RecordSheet.write(remembered, under: Self.key, in: store)
        }
    }

    private var board: [String: String] {
        RecordSheet.read([String: String].self, under: Self.key, from: store) ?? [:]
    }

    /// Brings over a board stored in the standard settings — **once.**
    @discardableResult
    public static func adopt(from legacy: UserDefaults, in store: any KeyValueStore) -> Bool {
        guard (try? store.value(for: key)) == nil,
            let old = legacy.dictionary(forKey: key) as? [String: String], !old.isEmpty
        else { return false }
        RecordSheet.write(old, under: key, in: store)
        guard RecordSheet.read([String: String].self, under: key, from: store) == old
        else { return false }
        legacy.removeObject(forKey: key)
        return true
    }

    /// The compartment in which an aspect ratio lies — `nil` if it cannot be one.
    ///
    /// **`nonisolated`, like the two calculations below:** they touch no state
    /// and so do not belong on the main thread. The class is, because of its store.
    ///
    /// Everything that describes no picture is filtered out: zero, negative, infinite, and what
    /// lies beyond 0.2 to 5.0. An engine that does not yet know a size reports 0 —
    /// forming a compartment from that would mean overwriting the memory of a real format.
    nonisolated static func bucket(_ ratio: Double) -> String? {
        guard ratio.isFinite, ratio >= 0.2, ratio <= 5 else { return nil }
        return String(format: "%.1f", ratio)
    }

    /// By how much the picture must grow to fill the screen.
    ///
    /// **The same in both directions.** A film that is wider than the screen lies
    /// with bars at top and bottom; one that is narrower, with bars left and right.
    /// Both times the factor is the ratio of the two ratios — only once
    /// one way round and once the other. That is why `max` and no case distinction.
    ///
    /// If one of the two is unusable, the factor is 1: then there is nothing to fill,
    /// and the gesture moves nothing instead of scaling to infinity.
    nonisolated static func fillFactor(image: Double, screen: Double) -> Double {
        guard image.isFinite, screen.isFinite, image > 0, screen > 0 else { return 1 }
        return max(image / screen, screen / image)
    }

    /// Where a pinch gesture snaps on release — **by its direction, not by
    /// its extent.**
    ///
    /// **Spreading fills, pinching in fits** — as in the TV app and on Netflix
    /// (on-device test build 1332, 2026-09-27: requirement that zoom goes via the two-finger gesture).
    /// Until then the measure snapped to the nearer of the two ends: with 16:9 on a
    /// 19.5:9 screen (factor 1.22) one had to spread the fingers by eleven percent, otherwise
    /// the picture jumped back, and a short, unambiguous gesture looked swallowed.
    /// The direction is what everybody brings from photos and maps; the extent is
    /// a coincidence of hand size.
    ///
    /// **A small dead zone** (``pinchThreshold``) remains: two fingers that merely
    /// rest tremble by one or two percent — that should not become a switch.
    ///
    /// - Parameters:
    ///   - vergroesserung: The magnification of the gesture, 1 = unchanged.
    ///   - lage: The state before the gesture — it continues to apply if the gesture says nothing.
    ///   - faktor: The fill factor (``fillFactor(image:screen:)``); without gain no snapping.
    nonisolated static func snaps(
        magnification: Double, from state: ImageLayout, factor: Double
    ) -> ImageLayout {
        guard factor > 1, magnification.isFinite else { return .fullImage }
        if magnification >= 1 + pinchThreshold { return .fillsScreen }
        if magnification <= 1 - pinchThreshold { return .fullImage }
        return state
    }

    /// How far the fingers must at least move apart or together before the gesture
    /// means anything — four percent.
    nonisolated static let pinchThreshold = 0.04
}
