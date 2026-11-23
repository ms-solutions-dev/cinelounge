import Testing

@testable import Core

/// Where the subtitle line moves when the picture is filled.
///
/// **The boundary is tested and not the middle.** Whether 74 instead of 90 comes out says little in
/// itself; the cases in which a bug would stay silent are the uncropped case
/// (the line must **not** move) and the horizontal crop, which does not touch the height at
/// all.
@Suite("Subtitles in the filled picture")
struct SubtitlePlacementTests {

    @Test("A wider picture crops left and right — the height stays whole")
    func widerPictureKeepsFullHeight() {
        // 21:9 on a 19.5:9 phone: filling happens across the width.
        let portion = SubtitleLayout.visibleFraction(image: 21.0 / 9, screen: 19.5 / 9)

        #expect(portion == 1)
        #expect(
            SubtitleLayout.linePlacement(visibleFraction: portion) == nil,
            "without a crop, what the viewer set in the system still applies")
    }

    @Test("A 4:3 home video loses a fifth at the top and at the bottom")
    func narrowerPictureCropsTopAndBottom() {
        let portion = SubtitleLayout.visibleFraction(image: 4.0 / 3, screen: 19.5 / 9)

        // 1.333 / 2.167 — barely two thirds of the height remain.
        #expect(abs(portion - 0.615) < 0.005)

        let row = try! #require(SubtitleLayout.linePlacement(visibleFraction: portion))
        // The margin at the top is (1 − 0.615) / 2 = 0.192; the line sits at nine tenths
        // of the remaining band, i.e. at 0.192 + 0.554 = 0.746.
        #expect(row == 75)
        #expect(row < 90, "it moves up and not down")
    }

    @Test("The line stays in the visible band — at every format")
    func theLineStaysInTheVisibleBand() {
        // **The actual promise of this type**, and the spot where a
        // sign error would stay silent: the number would look plausible and still lie in the
        // cropped-off margin.
        for image in [4.0 / 3, 1.5, 16.0 / 9, 1.85, 2.0] {
            let screen = 19.5 / 9
            let portion = SubtitleLayout.visibleFraction(image: image, screen: screen)
            guard let row = SubtitleLayout.linePlacement(visibleFraction: portion) else {
                continue
            }
            let top = (1 - portion) / 2 * 100
            let bottom = (1 + portion) / 2 * 100
            #expect(
                Double(row) > top && Double(row) < bottom,
                "at \(image) the line sits at \(row) % outside \(top)…\(bottom)")
        }
    }

    @Test("Almost fitting is no crop")
    func almostFittingIsNoCrop() {
        // 16:9 on 16:10 — a margin of one percent. Moving the line for that
        // would be a visible movement for an invisible gain.
        let portion = SubtitleLayout.visibleFraction(image: 1.6, screen: 1.62)

        #expect(portion > 0.98)
        #expect(SubtitleLayout.linePlacement(visibleFraction: portion) == nil)
    }

    @Test("An engine without a picture size moves nothing")
    func withoutPictureSizeNoCrop() {
        // The direct renderer reports 0 as long as it knows nothing. Inferring a crop from that
        // would mean moving the line for no reason.
        #expect(SubtitleLayout.visibleFraction(image: 0, screen: 2.16) == 1)
        #expect(SubtitleLayout.visibleFraction(image: 1.78, screen: 0) == 1)
        #expect(SubtitleLayout.visibleFraction(image: .nan, screen: 2.16) == 1)
        #expect(SubtitleLayout.visibleFraction(image: .infinity, screen: 2.16) == 1)
    }
}
