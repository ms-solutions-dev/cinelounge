import CoreMedia
import Foundation
import Testing

@testable import Core

/// The description of the picture stream as a file stores it — `hvcC`, `avcC`.
@Suite("Descriptions from the file header")
struct VideoConfigurationTests {

    static func video(_ name: String) throws -> Matroska.Track {
        let data = try MatroskaTests.fixture(name)
        return try #require(Matroska.header(from: data)?.video)
    }

    /// **It is counted, not searched** — and that is why it is unambiguous here. A
    /// start pattern can appear by chance in picture data, a length cannot.
    @Test("Units are separated by their length")
    func lengthPrefixedUnits() {
        let data = Data([0, 0, 0, 2, 0x40, 0x01, 0, 0, 0, 3, 0x42, 0x01, 0x02])
        let units = VideoConfiguration.units(inLengthPrefixed: data, lengthSize: 4)
        #expect(units == [Data([0x40, 0x01]), Data([0x42, 0x01, 0x02])])

        // A length beyond the edge means: miscounted. Better then to
        // stop than to guess.
        let broken = Data([0, 0, 0, 99, 0x40])
        #expect(VideoConfiguration.units(inLengthPrefixed: broken, lengthSize: 4).isEmpty)
    }
}
