import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import Styling

/// Font, dimensions, stripes and profile values — **roles shared, values per device, nothing
/// moved.** The numbers are recorded here because each of them is visible on a device;
/// whoever changes one should notice it at this place.
@Suite("Scales per device")
struct ScaleTests {

    @Test("The font sizes of the TV are the measured ones")
    func textTV() {
        #expect(
            TypeLevel.allCases.map { $0.points(.tv) } == [76, 57, 48, 38, 29, 27, 27, 25])
        #expect(TypeLevel.text.points(.tv) >= 29)
    }

    @Test("The type levels of the phone are the text styles")
    func textPhone() {
        #expect(
            TypeLevel.allCases.map { $0.points(.phone) } == [34, 28, 22, 17, 17, 15, 13, 11])
        #expect(TypeLevel.lead.font(.phone) == Font.largeTitle.weight(.bold))
        #expect(TypeLevel.header.font(.phone) == Font.headline)
        #expect(TypeLevel.lowercased.font(.phone) == Font.caption2.weight(.semibold))
    }

    @Test("The levels fall, none rises", arguments: UIPlatform.allCases)
    func ranking(platform: UIPlatform) {
        let sizes = TypeLevel.allCases.map { $0.points(platform) }
        #expect(zip(sizes, sizes.dropFirst()).allSatisfy { $0 >= $1 })
    }

    @Test("Line height: two factors, rounded up")
    func lineHeight() {
        #expect(TypeLevel.lineHeight(zu: 38, .tv) == 49)
        #expect(TypeLevel.lineHeight(zu: 17, .phone) == 23)
    }

    @Test("Poster 2 : 3, episode 16 : 9", arguments: UIPlatform.allCases)
    func aspectRatios(platform: UIPlatform) {
        let metrics = MetricsBoard.forItem(platform)
        #expect(abs(metrics.poster.width / metrics.poster.height - 2.0 / 3.0) < 0.001)
        #expect(abs(metrics.episode.width / metrics.episode.height - 16.0 / 9.0) < 0.02)
    }

    @Test("The metrics are those from before the move")
    func metrics() {
        let tv = MetricsBoard.tv
        #expect(
            [tv.imageRadius, tv.cardRadius, tv.fieldRadius, tv.sheetRadius] == [12, 12, 16, 28])
        #expect([tv.margin, tv.gutter, tv.section, tv.person] == [80, 40, 56, 168])
        let phone = MetricsBoard.phone
        #expect(
            [phone.imageRadius, phone.cardRadius, phone.fieldRadius, phone.sheetRadius]
                == [10, 10, 14, 20])
        #expect([phone.margin, phone.gutter, phone.section, phone.person] == [20, 12, 20, 64])
    }

    /// Six points on the phone correspond to about thirteen on the TV — carrying one
    /// device's numbers over to the other would carry its viewing conditions along.
    @Test("The stripes are calculated per device")
    func stripes() {
        #expect(StripeMetrics.tv.stripeWidth == 13)
        #expect(StripeMetrics.tv.bandHeight == 11)
        #expect(StripeMetrics.phone.stripeWidth == 6)
        #expect(StripeMetrics.phone.bandHeight == 4)
        #expect(StripeMetrics.tv.laneWidth == 620)
        #expect(StripeMetrics.phone.laneWidth == nil)
    }
}

@Suite("Profile brand and profile image")
struct ProfileBrandTests {

    @Test("Six brands, six different values, and no color for unknowns")
    func marks() {
        let values = ProfileBrand.names.compactMap(ProfileBrand.value)
        #expect(values.count == 6)
        #expect(Set(values).count == 6)
        #expect(ProfileBrand.value("bernstein") == 0xD3A850)
        #expect(ProfileBrand.value("doesnotexist") == nil)
        #expect(ProfileBrand.color("doesnotexist") == nil)
    }

    /// The brightness ladder: Any two brand colours differ even when the hue
    /// is lost (deuteranopia, three metres).
    @Test("The brands stand on a brightness ladder")
    func ladder() {
        let contrasts = ProfileBrand.names.compactMap(ProfileBrand.value).map {
            Contrast.ratio($0, 0x000000)
        }
        #expect(zip(contrasts, contrasts.dropFirst()).allSatisfy { $1 / $0 > 1.1 })
    }

    @Test("The reader accepts #RRGGBB with and without the hash and nothing else")
    func reader() {
        #expect(ProfileBrand.value(from: "#E2564A") == 0xE2564A)
        #expect(ProfileBrand.value(from: " e2564a ") == 0xE2564A)
        #expect(ProfileBrand.value(from: "#f00") == nil)
        #expect(ProfileBrand.value(from: "") == nil)
        #expect(ProfileBrand.value(from: nil) == nil)
        #expect(ProfileBrand.value(from: "#GGGGGG") == nil)
    }

    @Test("The band lies around the center of the face and stays in the picture")
    func band() {
        #expect(ProfileImage.bandTop(midpoint: 0.4, width: 400, height: 100) == 110)
        #expect(ProfileImage.bandTop(midpoint: 0.0, width: 400, height: 100) == 0)
        #expect(ProfileImage.bandTop(midpoint: 1.0, width: 400, height: 100) == 300)
        #expect(ProfileImage.bandTop(midpoint: 0.5, width: 80, height: 100) == 0)
    }

    @Test("The gradient is a variant, the fallback stays per device")
    func history() {
        #expect(ProfileGradient.forItem(.tv).brandTop == 0.42)
        #expect(ProfileGradient.forItem(.phone).brandTop == 0.55)
        #expect(ProfileGradient.forItem(.tv).fallback == .brandLight)
        #expect(ProfileGradient.forItem(.phone).fallback == .surfaceHigh)
    }
}

@Suite("Image color")
struct ImageColorTests {

    static func surface(_ red: UInt8, _ green: UInt8, _ blue: UInt8) throws -> CGImage {
        let page = 8
        var points = [UInt8](repeating: 255, count: page * page * 4)
        for i in stride(from: 0, to: points.count, by: 4) {
            points[i] = red
            points[i + 1] = green
            points[i + 2] = blue
        }
        let data = try #require(CGDataProvider(data: Data(points) as CFData))
        return try #require(
            CGImage(
                width: page, height: page, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: page * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: data, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test("Computation uses 96 × 96 pixels")
    func edge() throws {
        let points = try #require(ImageColor.pixels(from: try Self.surface(200, 30, 20)))
        #expect(ImageColor.edge == 96)
        #expect(points.count == 96 * 96 * 4)
    }

    @Test("Gray yields no color statement")
    func gray() throws {
        #expect(ImageColor.color(from: try Self.surface(128, 128, 128)) == nil)
    }
}
