import CoreGraphics
import Testing

@testable import Styling

/// **The child UI is one rule for both devices** (G3, finding B3): the same
/// enlargement, the same "less text", the dimensions from the device's board.
@Suite("Form of the child surface")
struct SurfaceTests {

    @Test("The kind decides, not the lock")
    func kind() {
        #expect(Surface.forItem(kind: true) == .kind)
        #expect(Surface.forItem(kind: false) == .familiar)
    }

    @Test("A child gets 1.3x posters on both devices", arguments: UIPlatform.allCases)
    func posters(platform: UIPlatform) {
        let board = MetricsBoard.forItem(platform)
        #expect(Surface.familiar.posterSize(to: board) == board.poster)
        let kind = Surface.kind.posterSize(to: board)
        #expect(kind.width == board.poster.width * 1.3)
        #expect(kind.height == board.poster.height * 1.3)
    }

    @Test("On the TV the measured size from AP45 stays")
    func tv() {
        #expect(Surface.kind.posterSize(to: .tv) == CGSize(width: 312, height: 468))
    }

    @Test("Measured tile widths grow along, familiar ones stay")
    func tileWidth() {
        #expect(Surface.familiar.enlarged(107) == 107)
        #expect(Surface.kind.enlarged(107) == 139)
    }

    @Test("Less text and no wide images only for the child")
    func extras() {
        #expect(Surface.familiar.showsExtras && Surface.familiar.showsWideImages)
        #expect(!Surface.kind.showsExtras && !Surface.kind.showsWideImages)
    }
}
