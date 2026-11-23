import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import DesignSystemPhone

/// The store that survives an app restart — and the reason it exists.
@Suite("Image store")
struct ImageStoreTests {

    /// A single-color image in the desired size.
    private func image(edge: Int) -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard
            let field = CGContext(
                data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        field.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        field.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
        return field.makeImage()
    }

    func ownFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("imagestore-\(UUID().uuidString)", isDirectory: true)
    }

    /// The purpose of the store in one sentence: what has been fetched once is there the next
    /// time — even after a restart, because then memory is empty.
    @Test("What was stored comes back in the same dimensions")
    func thereAndBack() async throws {
        let folder = ownFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore(folder: folder)
        let template = try #require(image(edge: 64))

        await store.create(template, under: "https://example.invalid/poster|160")
        let back = await store.image(for: "https://example.invalid/poster|160")

        #expect(back?.width == 64)
        #expect(back?.height == 64)
    }

    @Test("An unknown key returns nothing")
    func unknown() async {
        let folder = ownFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(await ImageStore(folder: folder).image(for: "never stored") == nil)
    }

    /// **An image address carries the name of the media server.** A folder full of file names
    /// with the home server in them would be exactly the trace that `Redaction` otherwise
    /// prevents everywhere.
    @Test("The file name does not reveal the address")
    func noAddressInFilename() async throws {
        let folder = ownFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore(folder: folder)
        let template = try #require(image(edge: 32))

        await store.create(template, under: "http://mediaserver.example.invalid:8096/Items/42|160")

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!names.isEmpty)
        for name in names {
            #expect(!name.contains("mediaserver"))
            #expect(!name.contains("8096"))
        }
    }

    /// Above the limit, the least recently used goes first — the same rule as in memory, so that
    /// the two tiers do not contradict each other.
    @Test("Above the upper limit it is cleaned up, exactly once")
    func clear() async throws {
        let folder = ownFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A limit of one byte clears everything down to nothing.
        let store = ImageStore(upperLimit: 1, folder: folder)
        let template = try #require(image(edge: 64))
        for number in 0..<3 {
            await store.create(template, under: "entry-\(number)")
        }
        #expect(await store.size() > 0)

        await store.cleanUpOnce()
        #expect(await store.size() == 0)

        // The second call does not count through again: with a few thousand files that costs
        // noticeable time, and when paging through a shelf it would happen twenty times.
        await store.create(template, under: "after")
        await store.cleanUpOnce()
        #expect(await store.size() > 0)
    }
}

extension ImageStoreTests {

    /// **The bug of 2026-09-05**, which was visible only on screen: a title logo is cut out, JPEG has
    /// no alpha channel — and on the first read from the store, a white block stood in the middle
    /// of the background image instead of the logo.
    @Test("A cut-out image is stored as PNG, a poster as JPEG")
    func formatFollowsTransparency() throws {
        let space = CGColorSpaceCreateDeviceRGB()

        let withAlpha = try #require(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage())
        #expect(ImageStore.format(forItem: withAlpha) == .png)

        let withoutAlpha = try #require(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )?.makeImage())
        #expect(ImageStore.format(forItem: withoutAlpha) == .jpeg)
    }

    /// Transparency must really survive the trip via disk — choosing the format is not enough if
    /// the downscaler loses it along the way.
    @Test("Transparency survives the trip to disk")
    func alphaSurvives() async throws {
        let folder = ownFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore(folder: folder)
        let space = CGColorSpaceCreateDeviceRGB()
        let field = try #require(
            CGContext(
                data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let lettering = try #require(field.makeImage())

        await store.create(lettering, under: "lettering|160")
        let back = try #require(await store.image(for: "lettering|160"))

        #expect(back.alphaInfo != .none)
        #expect(back.alphaInfo != .noneSkipLast)
        #expect(back.alphaInfo != .noneSkipFirst)
    }
}
