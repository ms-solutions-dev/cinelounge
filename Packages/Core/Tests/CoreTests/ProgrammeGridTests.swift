import Foundation
import Testing

@testable import Core

/// **The grid calculates before it draws** (AP14, 2026-09-02).
///
/// The rules that stand here decide about operability: a row without cells has
/// nothing on which focus can land, and two cells on top of each other are not a
/// programme but a drawing error.
@Suite("Programme grid: the rows of a window")
struct ProgrammeGridTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func time(_ hours: Double) -> Date {
        now.addingTimeInterval(hours * 3600)
    }

    private func makeChannel(_ id: String, epg: String? = "epg-\(1)") -> Channel {
        Channel(
            id: id, name: "Channel \(id)", streamURL: URL(string: "http://x/\(id).m3u8")!,
            playlistID: "list", epgID: epg)
    }

    private func broadcast(
        _ id: String, _ title: String, from: Double, to: Double, channel: String = "epg-1"
    ) -> Programme {
        Programme(
            id: id, channelID: channel, title: title, start: time(from), end: time(to))
    }

    // MARK: - Das Loch ist der Normalfall

    /// 89 percent of the channels of the test provider have no EPG. An empty row would
    /// not only be ugly but **inoperable**.
    @Test("A channel without a programme gets one cell across the whole window")
    func channelWithoutGuideGetsOneCell() {
        let rows = ProgramGrid.rows(
            channels: [makeChannel("1", epg: nil)], programs: [:],
            from: time(0), until: time(2), now: now)

        let cells = rows[0].cells
        #expect(cells.count == 1)
        #expect(cells[0].isGap)
        #expect(cells[0].title == "Channel 1")
        #expect(cells[0].visibleFrom == time(0))
        #expect(cells[0].visibleUntil == time(2))
        #expect(!rows[0].hasProgram)
    }

    @Test("A gap between two broadcasts becomes a cell itself")
    func gapsBecomeCells() {
        let rows = ProgramGrid.rows(
            channels: [makeChannel("1")],
            programs: [
                "epg-1": [
                    broadcast("a", "First", from: 0, to: 0.5),
                    broadcast("b", "Second", from: 1.5, to: 2),
                ]
            ],
            from: time(0), until: time(2), now: now)

        let cells = rows[0].cells
        #expect(cells.count == 3)
        #expect(cells.map(\.isGap) == [false, true, false])
        // Gapless: every cell begins where the previous one ends.
        for (links, right) in zip(cells, cells.dropFirst()) {
            #expect(links.visibleUntil == right.visibleFrom)
        }
    }

    /// **Second-long slivers are not a cell.** In XMLTV a few seconds regularly gape
    /// between two broadcasts; as cells they would be a line nobody can hit — and in the
    /// focus path a station without content.
    @Test("A gap of seconds does not become a cell of its own")
    func tinyGapsAreSwallowed() {
        let rows = ProgramGrid.rows(
            channels: [makeChannel("1")],
            programs: [
                "epg-1": [
                    broadcast("a", "First", from: 0, to: 1),
                    // Ten seconds later — below the limit.
                    Programme(
                        id: "b", channelID: "epg-1", title: "Second",
                        start: time(1).addingTimeInterval(10), end: time(2)),
                ]
            ],
            from: time(0), until: time(2), now: now)

        #expect(rows[0].cells.count == 2)
        #expect(rows[0].cells.allSatisfy { !$0.isGap })
    }

    // MARK: - Edges and overlaps

    @Test("What extends beyond the window is clipped and says so")
    func cellsAreClippedAndSaySo() {
        let rows = ProgramGrid.rows(
            channels: [makeChannel("1")],
            programs: ["epg-1": [broadcast("a", "Long Film", from: -1, to: 3)]],
            from: time(0), until: time(2), now: now)

        let cell = rows[0].cells[0]
        #expect(cell.visibleFrom == time(0))
        #expect(cell.visibleUntil == time(2))
        // The real times stay as they are — the board shows them.
        #expect(cell.start == time(-1))
        #expect(cell.end == time(3))
        #expect(cell.extendsLeft)
        #expect(cell.extendsRight)
        #expect(cell.visibleDuration == 2 * 3600)
    }

    /// **Verified on 2026-08-29:** this provider occupies the same channel in parallel — 290
    /// of 5512 rows. Two cells on top of each other would be a drawing error; the second
    /// drops out, and the number stays visible.
    @Test("A parallel broadcast is dropped — and counted")
    func overlappingProgrammesAreDroppedAndCounted() {
        let rows = ProgramGrid.rows(
            channels: [makeChannel("1")],
            programs: [
                "epg-1": [
                    broadcast("a", "First", from: 0, to: 2),
                    broadcast("b", "Parallel", from: 0.5, to: 1.5),
                ]
            ],
            from: time(0), until: time(2), now: now)

        #expect(rows[0].cells.count == 1)
        #expect(rows[0].cells[0].title == "First")
        #expect(rows[0].discarded == 1)
    }

    // MARK: - Die Lage

    @Test("Past, running, upcoming — measured against the current time")
    func placementIsMeasuredAgainstNow() {
        let rows = ProgramGrid.rows(
            channels: [makeChannel("1")],
            programs: [
                "epg-1": [
                    broadcast("a", "Past", from: -2, to: -1),
                    broadcast("b", "Running", from: -0.5, to: 0.5),
                    broadcast("c", "Upcoming", from: 1, to: 2),
                ]
            ],
            from: time(-2), until: time(2), now: now)

        let real = rows[0].cells.filter { !$0.isGap }
        #expect(real.map(\.state) == [.past, .running, .upcoming])
    }

    /// A window without extent yields no rows — and no crash.
    @Test("An empty window yields nothing")
    func emptyWindowYieldsNothing() {
        #expect(
            ProgramGrid.rows(
                channels: [makeChannel("1")], programs: [:],
                from: time(1), until: time(1), now: now
            ).isEmpty)
    }

    /// Several channels share one EPG identifier (HD and FHD) — both rows must show the
    /// same programme, each with its own identifier.
    @Test("Two channels on the same EPG ID both get their programme")
    func twoChannelsShareOneGuideID() {
        let rows = ProgramGrid.rows(
            channels: [makeChannel("hd"), makeChannel("fhd")],
            programs: ["epg-1": [broadcast("a", "Tagesfunke", from: 0, to: 1)]],
            from: time(0), until: time(1), now: now)

        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.cells.first?.title == "Tagesfunke" })
        #expect(rows.map(\.id) == ["hd", "fhd"])
        // The cells know which row they belong to — otherwise a press in the second row
        // would present the first channel.
        #expect(rows[1].cells.first?.channelID == "fhd")
    }
}
