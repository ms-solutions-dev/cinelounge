import Core
import Foundation
import PlaylistKit
import Testing

@testable import Features

/// The stopwatch on the view — E5, second part.
///
/// **What is measured.** ``SportModel/shown`` and
/// ``SportModel/availableKinds`` were computed properties, and the
/// view reads both while drawing: `shown` twice (once for the empty case,
/// once for the list), `availableKinds` once for the chip row. SwiftUI
/// redraws the area on **every focus step**. What is measured is therefore
/// exactly what a redraw costs at these three accesses — before, a
/// calculation, after, a glance at a stored value.
///
/// Measured on 2026-08-29 on an Apple M4, 54 rows (the number from the concept)
/// and 177 rows (what the recording yields over the whole stretch):
///
/// | Rows | before    | after     |
/// |-----:|----------:|----------:|
/// |   54 | 0.3975 ms | 0.0009 ms |
/// |  177 | 1.3353 ms | 0.0009 ms |
///
/// At 54 rows and the 44 focus steps that the concept counts up to the top game,
/// that is 18 ms of calculation for a single scroll-through — plus 44
/// trips to the Keychain. Afterwards it is nothing.
///
/// **The trip to the Keychain is not included here and goes away
/// in addition.** ``SportFilterSettings/load(from:)`` stood in
/// `availableKinds` and thereby ran on every redraw; on the device it talks
/// via ``SecureStore`` to the Keychain management. This test uses
/// an in-memory store — a check run that touched the Mac's Keychain
/// would depend on the environment it runs in. The calculation is
/// proven, the trip is not; it is therefore not quantified either.
///
/// Runs only with `CINELOUNGE_MESSUNG=1`, for the same reason as
/// ``ScheduleTimingTests``: a timing measurement is not an expectation. It fails
/// on a busy machine without anything being broken.
/// Whether the measurement should run. Outside the class, because `.enabled(if:)` reads it
/// from a `Sendable` closure — the isolation to the
/// main actor does not reach in there.
private let measurementRunning = ProcessInfo.processInfo.environment["CINELOUNGE_MESSUNG"] != nil

@MainActor
@Suite("Schedule view: measurement", .serialized)
struct SportViewMeasurementTests {

    /// A broadcast day in the desired size: lots of pairings, spread over the
    /// evening, on twenty channels.
    ///
    /// **The numbers start at 100, and that is not decoration.** The
    /// comparison core of a team drops words of a single character
    /// (``SportPlan/teamCore(_:)``) — with "Team 3" the first
    /// ten pairings fell onto the same key and were merged into a single
    /// row. The list was then 45 rows long instead of 54, and
    /// the measurement would have measured something other than it claims.
    static func broadcastDay(_ count: Int) -> [Programme] {
        (0..<count).map { number in
            let from = SportModelTests.moment(29, 15).addingTimeInterval(Double(number) * 180)
            return Programme(
                id: "p\(number)",
                channelID: "kanal\(number % 20).de",
                title: "Fussball: Mannschaft \(number + 100) - Gegner \(number + 100)",
                start: from,
                end: from.addingTimeInterval(7200))
        }
    }

    @Test(
        "What redrawing the list costs",
        .enabled(if: measurementRunning, "CINELOUNGE_MESSUNG is not set"))
    func redraw() async {
        for count in [54, 177] {
            let downloads = SportModelTests.downloads()
            await downloads.save(programmes: Self.broadcastDay(count))
            let library = LiveLibrary(
                store: PlaylistStore(
                    store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
                cache: downloads)

            let store = InMemoryStore()
            // A filled bookmark list: it is queried in every comparison of the
            // sorting; an empty one measures half.
            var watchlist = SportReminderList()
            watchlist.toggleTeam("Mannschaft 7")
            watchlist.toggleCompetition("Wettbewerb 3")
            let noteStore = SportModelTests.noteStore()
            noteStore.write(watchlist)

            let state = SportModelTests.now
            let model = SportModel(
                library: library, store: store, noteStore: noteStore,
                calendar: SportModelTests.calendar, clock: { state })
            await model.load()

            // Exactly the three accesses of a redraw.
            let iterations = 2000
            var sum = 0
            let start = Date()
            for _ in 0..<iterations {
                sum += model.shown.isEmpty ? 0 : 1
                sum += model.shown.count
                sum += model.availableKinds.count
            }
            let duration = Date().timeIntervalSince(start) / Double(iterations)
            print(
                String(
                    format: "  %3d Zeilen: ein Neuzeichnen %.4f ms   (%d gezaehlt)", count,
                    duration * 1000, sum))
        }
    }
}
