import CoreGraphics
import Foundation

/// Cache for loaded images — in memory.
///
/// **Why not `NSCache`.** It evicts at its own discretion and does not say when. For this
/// app exactly one property counts, though: it must shrink **on demand**. On iOS the memory
/// warning is sharper than on tvOS, and whoever ignores it is terminated in the background —
/// the viewer sees a restart on coming back instead of their place in the film. What happens
/// here is meant to be readable and to appear in the error log.
///
/// Eviction follows what has gone unused longest. A shelf one browses through thus keeps its
/// visible tiles, and the forty posters further to the left fall first.
///
/// - Note: Memory only. What is meant to stay permanently is the **downloads** and does not
///   belong here — an image cache that grows onto the disk later shows up in the storage
///   budget where nobody expects it.
public actor ImageCacheActor {

    public static let shared = ImageCacheActor()

    private struct Slot {
        let image: CGImage
        let cost: Int
        var recent: UInt64
        var color: ColorState = .notComputed
    }

    /// Whether the series color for this image has been calculated before.
    ///
    /// **Two states and no double `Optional`.** "Not yet calculated" and "calculated, and
    /// nothing came of it" are different answers: the one means calculate, the other means
    /// **not** calculating again. An `AccentPaletteValue??` would say the same and read like a
    /// typo at every evaluation.
    public enum ColorState: Sendable {
        case notComputed
        case computed(ImageLoader.AccentPaletteValue?)
    }

    private var slots: [String: Slot] = [:]
    private var clock: UInt64 = 0
    private let upperLimit: Int

    /// - Parameter obergrenze: how many bytes at most stay.
    public init(upperLimit: Int = 64 * 1024 * 1024) {
        self.upperLimit = upperLimit
    }

    public private(set) var taken = 0

    public func image(for key: String) -> CGImage? {
        guard var slot = slots[key] else { return nil }
        clock += 1
        slot.recent = clock
        slots[key] = slot
        return slot.image
    }

    /// What is known about the series color of this image.
    ///
    /// **It lies with the image and not in a second memo** — otherwise next to a store that
    /// cleans up, one that does not would grow, and both would mean the same images. This way
    /// the color falls out together with the image it belongs to.
    ///
    /// **Without an image no answer:** an access to an evicted tile reports `notComputed`, and
    /// that is true — it will be calculated again right away anyway, because the image has to
    /// be fetched again too.
    public func color(for key: String) -> ColorState {
        slots[key]?.color ?? .notComputed
    }

    /// Records the result — **the empty one too.**
    ///
    /// An image from which no color could be obtained gives the same none on the second attempt.
    /// Without this note the pass over every such image would run again on every display, and
    /// without result.
    public func memorize(color: ImageLoader.AccentPaletteValue?, under key: String) {
        guard var slot = slots[key] else { return }
        slot.color = .computed(color)
        slots[key] = slot
    }

    public func create(_ image: CGImage, under key: String) {
        let cost = image.height * image.bytesPerRow
        if let existing = slots[key] { taken -= existing.cost }
        clock += 1
        slots[key] = Slot(image: image, cost: cost, recent: clock)
        taken += cost
        evictDownTo(upperLimit)
    }

    /// Throws away until only a share of the upper limit is occupied.
    ///
    /// Not everything: an empty store means that on the next browse every visible poster is
    /// loaded again — and at exactly the moment when the system is short anyway, that is the
    /// most expensive answer.
    @discardableResult
    public func shrink(to portion: Double = 0.25) -> Int {
        let previous = taken
        evictDownTo(Int(Double(upperLimit) * portion))
        return previous - taken
    }

    public func clear() {
        slots.removeAll()
        taken = 0
    }

    private func evictDownTo(_ limit: Int) {
        guard taken > limit else { return }
        for key in slots.sorted(by: { $0.value.recent < $1.value.recent }).map(\.key) {
            guard taken > limit else { return }
            taken -= slots[key]?.cost ?? 0
            slots[key] = nil
        }
    }
}
