import CoreGraphics
import DesignSystemPhone
import Testing

@testable import FeaturesPhone

/// The tile width in the horizontal shelf.
///
/// **Why this needs a check and not an eyeball** (AP4): The error at issue
/// was invisible on **one** device and present on every other. Whoever looks for it on the
/// simulator looks at 402 points — and exactly there the peek was
/// smallest. A calculation is checked at all widths at once.
@Suite("Shelf metrics")
struct ShelfMetricsTests {

    /// The widths that really exist — from the smallest supported to the
    /// largest. No made-up intermediate values: What stands here can be ordered.
    private let widths: [(name: String, points: CGFloat)] = [
        ("iPhone SE", 375), ("iPhone 15/16", 393),
        ("iPhone 16 Pro", 402), ("iPhone 16 Pro Max", 440),
    ]

    /// **The finding itself, as a check.** Before: 7 points of peek on one device,
    /// 46 on the other. After, it must be about as wide as the margin everywhere —
    /// "about", because the tile width is rounded down and the remainder lands in the peek.
    @Test("The peek is about one margin wide on every device")
    func peekEverywhereSame() {
        for (name, width) in widths {
            for wide in [false, true] {
                let w = ShelfMetrics.tileWidth(at: width, wide: wide, sizeClass: .compact)
                let visibleCount = CGFloat(
                    wide ? ShelfMetrics.visibleWide(.compact) : ShelfMetrics.visible(.compact))
                let taken =
                    MetricsBoard.phone.margin + visibleCount * w + visibleCount * MetricsBoard.phone.gutter
                let peek = width - taken

                #expect(
                    peek >= ShelfMetrics.peek,
                    "\(name)\(wide ? " wide" : ""): peek \(peek) is too narrow")
                #expect(
                    peek < ShelfMetrics.peek + visibleCount,
                    "\(name)\(wide ? " wide" : ""): peek \(peek) is more than the rounding — then the calculation is wrong, not the rest"
                )
            }
        }
    }

    /// **Three whole tiles must fit in**, otherwise it is not a shelf with a peek
    /// but one with a cut-off third column.
    @Test("Three whole posters fit every width, two wide ones too")
    func wholeTilesFit() {
        for (name, width) in widths {
            let isNarrow = ShelfMetrics.tileWidth(at: width, sizeClass: .compact)
            #expect(
                MetricsBoard.phone.margin + 3 * isNarrow + 3 * MetricsBoard.phone.gutter <= width,
                "\(name): three posters do not fit")

            let wideTile = ShelfMetrics.tileWidth(at: width, wide: true, sizeClass: .compact)
            #expect(
                MetricsBoard.phone.margin + 2 * wideTile + 2 * MetricsBoard.phone.gutter <= width,
                "\(name): two wide tiles do not fit")
        }
    }

    /// **Bigger screen, bigger tile** — that is the whole purpose. A calculation
    /// that yields the same tile on a Pro Max as on an SE has solved nothing.
    @Test("The tile grows with the screen")
    func tileGrowsWith() {
        let isNarrow = ShelfMetrics.tileWidth(at: 375, sizeClass: .compact)
        let ample = ShelfMetrics.tileWidth(at: 440, sizeClass: .compact)

        #expect(ample > isNarrow)
        #expect(ample - isNarrow > 15, "the difference must be visible, not just measurable")
    }

    /// **The lower bound catches the case in which nothing has been measured yet.** Without it
    /// a tile of zero or negative width would come out, and SwiftUI draws nothing from it
    /// without complaining — an empty shelf that looks like a load error.
    @Test("At a nonsensical width a minimum tile remains")
    func minimumWidth() {
        #expect(ShelfMetrics.tileWidth(at: 0, sizeClass: .compact) == 60)
        #expect(ShelfMetrics.tileWidth(at: -100, sizeClass: .compact) == 60)
        #expect(ShelfMetrics.tileWidth(at: 50, sizeClass: .compact) == 60)
    }

    /// The height comes from the ratio and not from a second number — otherwise there are
    /// two opportunities to lose the ratio.
    @Test("The height keeps the aspect ratio")
    func heightKeepsRatio() {
        let w = ShelfMetrics.tileWidth(at: 393, sizeClass: .compact)
        let h = ShelfMetrics.tileHeight(zu: w)
        #expect(abs(w / h - MetricsBoard.phone.poster.width / MetricsBoard.phone.poster.height) < 0.01)

        let wb = ShelfMetrics.tileWidth(at: 393, wide: true, sizeClass: .compact)
        let hb = ShelfMetrics.tileHeight(zu: wb, wide: true)
        #expect(abs(wb / hb - MetricsBoard.phone.episode.width / MetricsBoard.phone.episode.height) < 0.01)
    }
}
