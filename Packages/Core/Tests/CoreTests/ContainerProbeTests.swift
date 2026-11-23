import Foundation
import Testing

@testable import Core

/// The container from the bytes instead of from the name — AP3 · V3c.
///
/// **The finding:** If the file is called `.mp4`, it goes straight to direct delivery,
/// and the repackager is never asked. The name comes from the provider's Xtream
/// information, and that is a claim.
@Suite("The container from the bytes")
struct ContainerProbeTests {

    /// A Matroska begins with the EBML head piece.
    @Test("Matroska is recognized")
    func matroska() {
        var bytes = Data([0x1A, 0x45, 0xDF, 0xA3])
        bytes.append(Data(repeating: 0, count: 100))
        #expect(MediaSource.Container.fromBytes(bytes) == .mkv)
    }

    /// **And this is the case it is all about:** A Matroska that is called `.mp4`. The
    /// bytes contradict the name, and they are right.
    @Test("The name lies, the bytes do not")
    func nameLies() {
        let claimed = MediaSource.Container(rawValue: "mp4")
        var bytes = Data([0x1A, 0x45, 0xDF, 0xA3])
        bytes.append(Data(repeating: 0, count: 100))

        #expect(claimed == .mp4)
        #expect(MediaSource.Container.fromBytes(bytes) == .mkv)
    }

    /// `ftyp` stands after the box length, so at position 4.
    @Test("The ISO family is recognized")
    func isoFamily() {
        var bytes = Data([0x00, 0x00, 0x00, 0x20])
        bytes.append(contentsOf: Array("ftypisom".utf8))
        bytes.append(Data(repeating: 0, count: 100))
        #expect(MediaSource.Container.fromBytes(bytes) == .mp4)
    }

    /// The transport stream has no head piece but a grid: 0x47 every 188 bytes.
    @Test("The transport stream grid is recognized")
    func transportStream() {
        var bytes = Data(repeating: 0, count: 4 * 188)
        for location in stride(from: 0, to: 4 * 188, by: 188) { bytes[location] = 0x47 }
        #expect(MediaSource.Container.fromBytes(bytes) == .ts)
    }

    /// **A single 0x47 is no transport stream.** Without the grid every file that happens
    /// to begin with `G` would be one — and the repackager would get something it cannot
    /// read.
    @Test("A single 0x47 is not enough")
    func singleGridCharacter() {
        var bytes = Data(repeating: 0, count: 4 * 188)
        bytes[0] = 0x47
        #expect(MediaSource.Container.fromBytes(bytes) == nil)
    }

    /// If the bytes say nothing, it stays with the name: A claim is still always better
    /// than no statement at all.
    @Test("Silence is not a finding")
    func staySilent() {
        #expect(MediaSource.Container.fromBytes(Data(repeating: 0x11, count: 900)) == nil)
        #expect(MediaSource.Container.fromBytes(Data([0x01, 0x02])) == nil)
    }

    // MARK: - When probing happens at all

    /// **Only where the answer can change something.** If the information claims a
    /// container that Apple's engine does not open anyway, it is repackaged — if the
    /// claim is wrong there, the repackager notices itself.
    @Test("Only a claimed Apple container is probed")
    func paysOffOnlyThere() {
        #expect(ContainerProbe.isWorthwhile(claimed: .mp4, hasMediaServer: false))
        #expect(!ContainerProbe.isWorthwhile(claimed: .mkv, hasMediaServer: false))
    }

    /// And never for Jellyfin: Its values come from its own analysis of the file and not
    /// from a list.
    @Test("The media server is not probed")
    func notMediaServer() {
        #expect(!ContainerProbe.isWorthwhile(claimed: .mp4, hasMediaServer: true))
    }
}
