import CoreGraphics
import Testing

@testable import DesignSystemPhone

@Suite("Image storage")
struct ImageCacheActorTests {

    /// An image of known size — so that the costs can be recomputed in the test.
    private func image(edge: Int) -> CGImage {
        let surface = CGContext(
            data: nil, width: edge, height: edge, bitsPerComponent: 8,
            bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return surface.makeImage()!
    }

    @Test("What goes in comes out")
    func putAndGet() async {
        let storage = ImageCacheActor()
        await storage.create(image(edge: 32), under: "a")
        #expect(await storage.image(for: "a") != nil)
        #expect(await storage.image(for: "b") == nil)
    }

    @Test("Above the upper limit the oldest goes first")
    func evictsOldest() async {
        // Three images of 32 × 32 × 4 bytes each do not fit into two of them.
        let oneImage = 32 * 32 * 4
        let storage = ImageCacheActor(upperLimit: oneImage * 2 + 1)

        await storage.create(image(edge: 32), under: "old")
        await storage.create(image(edge: 32), under: "middle")
        // "old" is needed again and thereby moves to the front.
        _ = await storage.image(for: "old")
        await storage.create(image(edge: 32), under: "new")

        #expect(await storage.image(for: "middle") == nil)
        #expect(await storage.image(for: "old") != nil)
        #expect(await storage.image(for: "new") != nil)
    }

    /// The property that is why it is not an `NSCache`: it must shrink on demand when the system
    /// asks for memory back.
    @Test("Shrink on demand — but not to zero")
    func shrinks() async {
        let oneImage = 64 * 64 * 4
        let storage = ImageCacheActor(upperLimit: oneImage * 8)
        for number in 1...8 {
            await storage.create(image(edge: 64), under: "b\(number)")
        }
        let previous = await storage.taken
        let unrestricted = await storage.shrink(to: 0.5)

        #expect(unrestricted > 0)
        #expect(await storage.taken < previous)
        // Not empty: an empty store means that on the next paging every visible poster is reloaded —
        // and exactly when memory is tight anyway.
        #expect(await storage.taken > 0)
    }

    @Test("Storing the same twice counts once")
    func noDoubleCounting() async {
        let storage = ImageCacheActor()
        await storage.create(image(edge: 32), under: "a")
        let once = await storage.taken
        await storage.create(image(edge: 32), under: "a")
        #expect(await storage.taken == once)
    }

    // MARK: - The series color sits with the image

    @Test("Without a calculation nothing is known, after it something is")
    func colorIsRemembered() async {
        let storage = ImageCacheActor()
        await storage.create(image(edge: 32), under: "a")

        guard case .notComputed = await storage.color(for: "a") else {
            Issue.record("freshly stored means not computed")
            return
        }

        await storage.memorize(
            color: ImageLoader.AccentPaletteValue(hue: 0.5, saturation: 0.4), under: "a")

        guard case .computed(let remembered) = await storage.color(for: "a") else {
            Issue.record("after the note it must read computed")
            return
        }
        #expect(remembered?.hue == 0.5)
    }

    /// **The case that otherwise silently recomputed every time.** An image without an
    /// extractable color yields none again on the second attempt — "computed, nothing in it" must
    /// therefore be distinguishable from "not yet computed".
    @Test("The empty result is remembered too")
    func emptyResultCountsToo() async {
        let storage = ImageCacheActor()
        await storage.create(image(edge: 32), under: "a")
        await storage.memorize(color: nil, under: "a")

        guard case .computed(let remembered) = await storage.color(for: "a") else {
            Issue.record("nil is a result and not a missing one")
            return
        }
        #expect(remembered == nil)
    }

    /// The color drops out together with its image — otherwise, next to a store that cleans up,
    /// one that does not would grow.
    @Test("When the image is evicted, the color goes too")
    func colorDropsWithImage() async {
        let oneImage = 32 * 32 * 4
        let storage = ImageCacheActor(upperLimit: oneImage + 1)
        await storage.create(image(edge: 32), under: "old")
        await storage.memorize(
            color: ImageLoader.AccentPaletteValue(hue: 0.1, saturation: 0.2), under: "old")

        await storage.create(image(edge: 32), under: "new")

        #expect(await storage.image(for: "old") == nil)
        guard case .notComputed = await storage.color(for: "old") else {
            Issue.record("the color goes with the image")
            return
        }
    }

    /// A note for an image that is not stored at all creates no entry — otherwise the store of
    /// keys without images would grow.
    @Test("Without an image nothing is noted")
    func noteWithoutImageCreatesNothing() async {
        let storage = ImageCacheActor()
        await storage.memorize(
            color: ImageLoader.AccentPaletteValue(hue: 0.3, saturation: 0.3), under: "missing")

        guard case .notComputed = await storage.color(for: "missing") else {
            Issue.record("a note without an image must not create anything")
            return
        }
        #expect(await storage.taken == 0)
    }
}
