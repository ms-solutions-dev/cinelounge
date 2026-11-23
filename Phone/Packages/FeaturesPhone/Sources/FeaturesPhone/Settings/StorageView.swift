import Core
import DesignSystemPhone
import Downloads
import Flows
import SwiftUI

/// Area 10 · Storage — **what really is on this device.**
///
/// **The finding of 2026-09-07:** this file was eight lines of comment. "What is on this device"
/// stood as a row under the account, ``TabPlaceholder`` had no branch for
/// ``ViewID/storage`` — and the viewer landed three taps away from Settings on
/// "speicher · not built yet" with three developer buttons. The same type of error as with
/// "Add account" (E23) and the Favorites tab (E26): linked but not built.
///
/// **The downloads have been included since 2026-09-08, and that was overdue.** They lie under
/// `Application Support/Vorrat` — thus within what "Other" had been adding up until then.
/// Fourteen gigabytes of films stood under a heading that suggests "can go"; exactly that is
/// what this screen warns against. They are now subtracted and listed separately, with the
/// statement that makes the difference: **stays until you delete.**
///
/// **One bar and not three numbers.** The distribution is the question one has for this
/// screen; three numbers one under another answer it only after mental arithmetic. iOS, Plex
/// and Infuse draw the same bar at this spot, for the same reason.
///
/// **ONE view with two doors** — from the downloads and from Settings. Two designers had
/// each built one independently, with the same items and different numbers; that is why this
/// sentence has stood here since the first version.
struct StorageView: View {
    @Environment(\.horizontalSizeClass) private var widthClass

    /// The downloads — **`nil` as long as nothing is set up.** Without them there is nothing to
    /// reconcile: "Reconcile" compares the files on disk with the entries, and without entries
    /// every file would be orphaned.
    var downloads: DownloadsManager?

    /// The way to the Downloads view — **because everything it needs is already there.**
    ///
    /// **The finding of 2026-09-12, from a product requirement:** when tapping on it one should
    /// be able to delete single items, mark several and delete them, or delete everything at
    /// once. That is exactly what ``DownloadsView`` has always been able to do: single items via the
    /// row, several via ``Downloads/BulkSelection`` and everything via "select all". A second
    /// management sheet here would be a second truth about the same catalog — and the worse one,
    /// because it does not know about downloading.
    ///
    /// **So this screen leads there and does not manage anything itself.** It answers "how much
    /// is here and of what"; deleting belongs where the titles are.
    var showDownloads: (() -> Void)?

    @State private var items: [StorageUsage.LineItem] = []
    @State private var unrestricted: Int64?
    @State private var cleaned: String?
    /// What the time-shift ring currently occupies (AP58 G1, A1).
    @State private var timeOffset: Int64 = 0

    /// The colors of the three items — **in the order of the items and not by meaning.** They
    /// distinguish sections of a bar and carry no judgment; that is why there is no red for
    /// "bad" here.
    ///
    /// **The downloads are gold, and at both places.** ``StorageLegend`` in the downloads
    /// colors it the same way; two screens that color the same thing differently are the little
    /// sister of two screens with different numbers.
    private static let colors: [Color] = [
        ColorRole.progress.color, ColorRole.tag.color, ColorRole.textMatt.color,
        ColorRole.textQuiet.color,
    ]

    private var taken: Int64 { items.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsCard {
                        bar.padding(Metrics.cardInset)
                        legend.padding(.horizontal, Metrics.cardInset)
                            .padding(.bottom, Metrics.cardInset)
                    }

                    Footnote(message: "storage.reserveText")
                        .padding(.bottom, MetricsBoard.phone.section)

                    SettingsCard(header: "storage.clean") {
                        // **The videos first, because they are the answer to the question one has for this
                        // screen.** The image cache is a cache of kilobytes; a downloaded film is gigabytes, and it
                        // stays until somebody deletes it.
                        //
                        // **It only appears if there are any.** A row "Videos 0 B" that leads into an empty list is
                        // a path into nothing.
                        if let showDownloads, bytes(from: "storage.videos") > 0 {
                            DisclosureRow(
                                title: "storage.manage", icon: Glyph.downloads.name,
                                value: StorageUsage.readable(bytes(from: "storage.videos")),
                                isContained: true, action: showDownloads)
                            Separator()
                        }
                        DisclosureRow(
                            title: "storage.images", icon: "photo",
                            value: StorageUsage.readable(bytes(from: "storage.images")),
                            isContained: true, action: clearImages)
                    }

                    Footnote(
                        message: bytes(from: "storage.videos") > 0
                            ? "storage.manageWhy" : "storage.imagesText")

                    // **The buffer for pausing channels, as on the TV** (AP58 G1, A1): occupied only while a
                    // channel is playing; the app launch clears it. The upper limit is the phone's
                    // (``Flows/TimeShift``).
                    Footnote(
                        wording: AppLanguageSetting.word(
                            "player.timeShiftUsage \(StorageUsage.readable(timeOffset)) \(StorageUsage.readable(TimeShift.capacity(.phone)))"
                        ))

                    // **"Reconcile" is the quieter of the two actions and still the more important one.** It
                    // finds files that no entry knows about anymore — the case arises through cancellation: a
                    // job that the system ended under storage pressure leaves bytes without a row. Without it
                    // the downloads would grow by files that nobody can delete.
                    if downloads != nil {
                        SettingsCard(header: "storage.stock") {
                            DisclosureRow(
                                title: "storage.reconcile", icon: Glyph.refresh.name,
                                isContained: true, action: reconcile)
                        }
                        Footnote(message: "storage.reconcileWhy")
                    }

                    if let cleaned {
                        HintRow(
                            icon: Glyph.done.pair.outlined, color: ColorRole.success.color,
                            title: "cache.freed %@", wording: cleaned
                        )
                        .padding(.top, MetricsBoard.phone.gutter)
                    }
                }
                .contentColumn(widthClass)
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
        .task { load() }
    }

    /// The bar — **used and free in one lane.**
    private var bar: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { surface in
                let total = Double(taken + (unrestricted ?? taken))
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { slot, part in
                        Rectangle()
                            .fill(Self.colors[slot % Self.colors.count])
                            .frame(
                                width: total > 0
                                    ? surface.size.width * (Double(part.bytes) / total) : 0)
                    }
                    Rectangle().fill(ColorRole.surfaceHigh.color)
                }
            }
            .frame(height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(verbatim: StorageUsage.readable(taken))
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)
        }
        .accessibilityElement(children: .combine)
    }

    private var legend: some View {
        // **Two columns and not one row.** Four items with sizes do not fit side by side at larger
        // system font sizes, and truncated the legend would be exactly what it is supposed to
        // explain. A wrapping flow would be the prettier form; it would also be a component of its
        // own, and so far exactly this one place needs it.
        LazyVGrid(
            columns: [
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading),
            ],
            alignment: .leading, spacing: 6
        ) {
            ForEach(Array(items.enumerated()), id: \.element.id) { slot, part in
                legendItem(
                    Self.colors[slot % Self.colors.count],
                    SettingsModel.text(part.id) + " " + StorageUsage.readable(part.bytes))
            }
            if let unrestricted {
                legendItem(
                    ColorRole.surfaceHigh.color,
                    SettingsModel.text("storage.free %@", StorageUsage.readable(unrestricted)))
            }
        }
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(verbatim: text)
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textMatt.color)
        }
    }

    private func load() {
        items = StorageUsage.items(downloads: downloadFiles)
        unrestricted = StorageUsage.unrestricted()
        timeOffset = TimeShift.taken()
    }

    /// Which files in the downloads belong to what.
    ///
    /// **The same calculation as in ``reconcile()``**, and that is why it stands here: two
    /// places that answer "which files does the download store know" differently would be two
    /// numbers about the same folder — and the one you forget is the one with the leftovers.
    private var downloadFiles: StorageUsage.DownloadFiles {
        guard let downloads else { return .unknown }
        let videos = Set(downloads.downloads.items.map { Store.fileName(forItem: $0.id) })
        let details =
            (try? Store.folder()).map { DescriptionLedger(folder: $0).knownFiles() } ?? []
        return .init(videos: videos, details: details)
    }

    /// **The image cache is the only item that can be thrown away without risk.**
    ///
    /// It is fetched again on next open; the log, on the other hand, is the information about
    /// what went wrong and is emptied at its own place (Diagnostics area, with confirmation).
    /// "Other" is accesses and history — for that there is Reset and no clean-up button.
    /// **What is orphaned is named and not silently deleted.** A reconcile that takes away
    /// fourteen gigabytes unasked is no reconcile but an accident — the message says how much
    /// was found, and deleting remains an action of its own.
    private func reconcile() {
        guard let downloads else { return }
        // **And the descriptions count too** (2026-09-09). Since every download has details and images
        // next to the file, the downloads folder knows more than films: posters, backgrounds, logos,
        // faces, plus the ledger itself. Without this row the reconcile would consider them all
        // orphaned and report a number that nobody can verify — nothing is deleted here, but an
        // invented number is worse than none.
        let known =
            Set(downloads.downloads.items.map { Store.fileName(forItem: $0.id) })
            .union(
                (try? Store.folder()).map { DescriptionLedger(folder: $0).knownFiles() }
                    ?? [])
        let onDisk =
            (try? FileManager.default.contentsOfDirectory(
                atPath: (try? Store.folder())?.path ?? "")) ?? []
        let orphans = Cleanup.orphaned(files: Set(onDisk), known: known)
        cleaned = "\(orphans.count)"
        load()
    }

    /// How big an item is — **looked up by identifier, not by position.**
    ///
    /// **The finding of 2026-09-12, visible in a screenshot:** in the clean-up row "Image cache"
    /// stood `246 kB`, in the legend above "Image cache 80 MB" — and `246 kB` was the value of
    /// the **downloads**. ``StorageUsage/items()`` returns `[storage.stock, storage.images,
    /// storage.log, storage.other]`, and two places accessed `.first`. The first item is the
    /// downloads.
    ///
    /// The second place was worse than the wrong number: ``clearImages()`` also measured before
    /// and after at `.first` — that is, at the downloads, which it does not touch. The message
    /// "this much was freed" was therefore **always zero**, even when eighty megabytes were
    /// cleared.
    ///
    /// **A position is not an identifier.** The order of the items is a question of display;
    /// whoever changes it should not shift two numbers in other places.
    private func bytes(from identifier: String) -> Int64 {
        items.first { $0.id == identifier }?.bytes ?? 0
    }

    private func clearImages() {
        let previous = StorageUsage.items().first { $0.id == "storage.images" }?.bytes ?? 0
        Task {
            await ImageStore.shared.clear()
            load()
            let after = StorageUsage.items().first { $0.id == "storage.images" }?.bytes ?? 0
            cleaned = StorageUsage.readable(max(0, previous - after))
        }
    }
}
