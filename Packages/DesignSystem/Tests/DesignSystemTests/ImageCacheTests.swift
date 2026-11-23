import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import DesignSystem

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// The cache is the answer to the most common complaint about
/// comparable apps. What is checked above all is the **cost calculation**: limiting by
/// count instead of by size was the error of the first version —
/// it added up to many times the permitted memory, and tvOS would have
/// terminated the app.
@Suite("Image cache")
struct ImageCacheTests {

    @Test("Memory cost follows pixels, not file size")
    func costIsBasedOnPixels() {
        // A poster of 240×360 points takes up about 1.3 MB decoded, the
        // file only about 200 KB. Anyone who counts the file miscalculates
        // by a factor of six.
        let small = PlatformImage(size: CGSize(width: 240, height: 360))
        let large = PlatformImage(size: CGSize(width: 1920, height: 1080))

        let smallCost = ImageCache.memoryCost(of: small)
        let largeCost = ImageCache.memoryCost(of: large)

        #expect(smallCost > 0)
        #expect(largeCost > smallCost * 20, "a backdrop costs many times a poster")
    }

    @Test("Four bytes per pixel")
    func costFormula() {
        let image = PlatformImage(size: CGSize(width: 100, height: 100))
        // 100 × 100 points × 4 bytes, times the scale factor squared.
        #expect(ImageCache.memoryCost(of: image) >= 100 * 100 * 4)
    }

    @Test("Unreachable addresses deliver nothing and occupy no space")
    func failureIsNotCached() async {
        // Short timeout, otherwise the test waits twice twenty seconds for an
        // address from the example range — twice as long since the second attempt.
        let cache = ImageCache(memoryLimit: 1024 * 1024, diskLimit: 1024 * 1024, requestTimeout: 2)
        let unreachable = URL(string: "http://192.0.2.1/image.jpg")!

        #expect(await cache.image(for: unreachable) == nil)
        // And afterwards the fast path is empty too: a failure must not stay stuck as a
        // result, otherwise the tile would never get anything.
        #expect(cache.cachedImage(for: unreachable) == nil)
    }

    // MARK: - Without waiting

    @Test("An existing image is available without waiting")
    func memoryAnswersSynchronously() {
        // **The test for the sentence "if they come from the cache, it should
        // be there immediately".** That is exactly what it hinged on: the store sat behind an
        // actor, and the way there and back cost one to two frames while
        // scrolling — visible as a flash of the placeholder on a tile that
        // had just been visible.
        let store = ImageMemory(limit: 4 * 1024 * 1024)
        let url = URL(string: "http://server/Items/1/Images/Primary")!
        let key = ImageCache.key(url, 480)

        #expect(store.object(key) == nil)

        let image = PlatformImage(size: CGSize(width: 100, height: 100))
        store.set(image, for: key, cost: ImageCache.memoryCost(of: image))

        #expect(store.object(key) != nil)
        // The same address at a different size is a different entry — otherwise the
        // poster of the grid tile would show up in the info column.
        #expect(store.object(ImageCache.key(url, 960)) == nil)
    }

    @Test("What was never fetched is not instantly there")
    func synchronousLookupMissesCleanly() async {
        let cache = ImageCache(memoryLimit: 1024, diskLimit: 1024)
        #expect(cache.cachedImage(for: URL(string: "http://server/unknown")!) == nil)
    }

    @Test("Clearing also empties the fast path")
    func clearEmptiesMemory() async {
        let cache = ImageCache(memoryLimit: 1024 * 1024, diskLimit: 1024 * 1024)
        let url = URL(string: "http://server/Items/2/Images/Primary")!
        let image = PlatformImage(size: CGSize(width: 40, height: 40))
        cache.memory.set(image, for: ImageCache.key(url, nil), cost: 1)

        #expect(cache.cachedImage(for: url) != nil)
        await cache.clear()
        #expect(cache.cachedImage(for: url) == nil)
    }

    // MARK: - Prefetch

    @Test("Prefetch skips what is already in memory")
    func prefetchSkipsCached() async {
        // At startup some of the posters are long since there — from the Home screen
        // or from the last pass. The prefetch must not send out a request for them;
        // the address here is unreachable, so a fetch would run into the timeout
        // and the test into its own.
        let cache = ImageCache(memoryLimit: 1024 * 1024, diskLimit: 1024 * 1024, requestTimeout: 2)
        let url = URL(string: "http://192.0.2.1/Items/1/Images/Primary")!
        let image = PlatformImage(size: CGSize(width: 40, height: 40))
        cache.memory.set(image, for: ImageCache.key(url, 480), cost: 1)

        await cache.prefetch([url], decodeLimit: 480)

        #expect(cache.cachedImage(for: url, decodeLimit: 480) != nil)
    }

    /// **The prefetch must not clog the line it is supposed to keep free.**
    ///
    /// The finding for this (2026-08-08): after the prefetch had learned to take a
    /// free slot, several ran at once — posters, channel logos,
    /// background image, cast, episodes. Each took only one of the three
    /// slots; together they took all three. After that a detail page loaded no
    /// cast photos at all.
    ///
    /// The lock is tested through its most dangerous property: if it stayed
    /// set after a run, **no** prefetch would ever run again — and nothing would be
    /// visible of it except images popping in.
    @Test("After the prefetch the slot is free again")
    func prefetchReleasesItsSlot() async {
        let cache = ImageCache(memoryLimit: 1024 * 1024, diskLimit: 1024 * 1024, requestTimeout: 1)
        // Unreachable on purpose: a failure too must release the lock.
        let url = URL(string: "http://192.0.2.1/Items/clogged/Images/Primary")!

        await cache.prefetch([url], decodeLimit: 480)

        #expect(await cache.prefetching == false)
    }

    /// Two prefetches at once are the normal case, not the exception — at
    /// startup posters and channel logos run side by side. Both must
    /// get through and must not hold each other up.
    @Test("Two prefetches at once do not deadlock")
    func twoPrefetchesDoNotDeadlock() async {
        let cache = ImageCache(memoryLimit: 1024 * 1024, diskLimit: 1024 * 1024, requestTimeout: 1)
        let first = URL(string: "http://192.0.2.1/Items/one/Images/Primary")!
        let second = URL(string: "http://192.0.2.1/Items/two/Images/Primary")!

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await cache.prefetch([first], decodeLimit: 480) }
            group.addTask { await cache.prefetch([second], decodeLimit: 480) }
        }

        #expect(await cache.prefetching == false)
    }

    /// **It asserted nothing** (AP6 · Q9): the body called and checked
    /// nothing — the test case would have stayed green even if `prefetch([])` had
    /// set the lock and never released it. That is exactly the case
    /// it is meant for.
    @Test("An empty prefetch returns immediately")
    func prefetchWithNothingToDo() async {
        let cache = ImageCache(memoryLimit: 1024, diskLimit: 1024)
        await cache.prefetch([])

        // The lock is open again — otherwise no later prefetch would get
        // through (the same trap as with the prefetch lock in AP7 · L5).
        #expect(await cache.prefetching == false)
    }

    // MARK: - Second attempt

    @Test("Only what is worth retrying is retried")
    func retryPolicy() {
        // No response means network or timeout — when the Home screen opens the
        // most common case, because several dozen tiles request at once.
        #expect(ImageCache.isWorthRetrying(status: nil))
        // The server has a temporary problem.
        #expect(ImageCache.isWorthRetrying(status: 503))
        // This image does not exist — the normal case for home videos. Asking again
        // only costs a connection that is missing elsewhere.
        #expect(!ImageCache.isWorthRetrying(status: 404))
        #expect(!ImageCache.isWorthRetrying(status: 401))
    }

    /// **This one asserted nothing either** (AP6 · Q9). "Throws no errors" is
    /// no statement on a function without `throws`; what was meant is that afterwards
    /// nothing is really left.
    @Test("After clearing the memory is empty")
    func clearing() async {
        let cache = ImageCache(memoryLimit: 1024, diskLimit: 1024)
        await cache.clear()

        // An image that was in it before can no longer be fetched afterwards —
        // and the running fetch is cancelled, not merely forgotten.
        #expect(cache.cachedImage(for: URL(string: "http://server/x")!) == nil)
        #expect(await cache.prefetching == false)
    }

    // MARK: - Key

    @Test("The same address in two sizes is two entries")
    func keyIncludesSize() {
        // Without the size in the key, the info column would get the poster at the
        // size of a grid tile, just because the same address was once fetched small
        // before — a blurry image with no recognizable cause.
        let url = URL(string: "http://server/Items/1/Images/Primary")!
        #expect(ImageCache.key(url, 480) != ImageCache.key(url, 720))
    }

    @Test("Without a size the key stays the address")
    func keyWithoutSize() {
        // The color derivation requests its image without a limit. Its entry must not
        // hinge on a number that does not exist there.
        let url = URL(string: "http://server/Items/1/Images/Primary")!
        #expect(ImageCache.key(url, nil) == url.absoluteString)
    }

    // MARK: - Decode downscaled

    @Test("Decoding with a limit really shrinks")
    func decodeRespectsLimit() throws {
        // The actual purpose: an image that is delivered larger than it is drawn
        // must not end up in memory at full size. Previously exactly that happened,
        // and the downscaling occurred on every draw on the main thread.
        let data = try Self.pngData(width: 1200, height: 800)

        let full = try #require(ImageCache.decode(data, limit: nil))
        let small = try #require(ImageCache.decode(data, limit: 300))

        #expect(ImageCache.memoryCost(of: small) < ImageCache.memoryCost(of: full))
        #expect(Self.pixelWidth(of: small) <= 300)
        #expect(Self.pixelWidth(of: full) == 1200)
    }

    @Test("The aspect ratio is kept when shrinking")
    func decodeKeepsAspect() throws {
        let data = try Self.pngData(width: 1200, height: 800)
        let small = try #require(ImageCache.decode(data, limit: 600))

        let ratio = Double(Self.pixelWidth(of: small)) / Double(Self.pixelHeight(of: small))
        #expect(abs(ratio - 1.5) < 0.02, "1200 by 800 is 3:2 and must stay so")
    }

    @Test("Unreadable data yields nothing — and does not crash")
    func decodeRejectsRubbish() {
        // A foreign channel list delivers what it wants. An error message at this
        // point is fine, a crash is not.
        #expect(ImageCache.decode(Data([0x00, 0x01, 0x02, 0x03]), limit: 200) == nil)
    }

    // MARK: - Helpers

    /// A real PNG at the desired size.
    ///
    /// Generated and not stored: the test is meant to pin down the **downscaling**, and
    /// for that the content is irrelevant — only the dimensions count.
    ///
    /// Via CoreGraphics and not via the platform's image class: the tests
    /// run on the Mac, the code on the TV, and `lockFocus` exists only
    /// on one of the two.
    static func pngData(width: Int, height: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.58, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let buffer = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return buffer as Data
    }

    /// The dimensions in **pixels** — not in points.
    ///
    /// The difference is exactly what this is about: on tvOS the result carries
    /// scale 2, so its size in points is half.
    static func pixelSize(of image: PlatformImage) -> (width: Int, height: Int) {
        #if canImport(UIKit)
            let cgImage = image.cgImage
        #else
            var rect = CGRect(origin: .zero, size: image.size)
            let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
        return (cgImage?.width ?? 0, cgImage?.height ?? 0)
    }

    static func pixelWidth(of image: PlatformImage) -> Int { pixelSize(of: image).width }
    static func pixelHeight(of image: PlatformImage) -> Int { pixelSize(of: image).height }
}
