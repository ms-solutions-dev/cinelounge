import Core
import DesignSystemPhone
import Downloads
import SwiftUI

/// Sheet: **add to downloads.**
///
/// The scope comes from the trigger, the choice below it from the source — and for each
/// that is a different question:
///
/// * **Jellyfin** offers levels, because the server transcodes.
/// * **The provider** offers a single version and not a list with one entry.
/// * **A portal** offers **language version and source**. The version comes **before**
///   the host, and that is not a question of sorting: resolution annoys on a plane, a wrong
///   audio track makes the title unusable — and choosing again does not work without a network.
///
/// **No switch between the sources.** The prototype has one so that all three
/// versions can be seen; in the app the source is known as soon as the sheet opens. A
/// switch here would be a question whose answer is already settled.
struct DownloadSheet: View {

    @State private var choice: DownloadChoice

    /// Add — **and whether the standing order is switched on in the process.**
    ///
    /// Two values and not one field on the job: the job describes **this**
    /// delivery, the standing order the series. Merging them would mean losing it
    /// when the episode is removed.
    let enqueue: (DownloadJob, Bool) -> Void

    /// Whether "Keep adding" is offered at all.
    ///
    /// **Only after the first finished download.** A standing order is a commitment about
    /// bandwidth and space; whoever has never seen a download cannot
    /// judge it. For a film the switch is never there — there is nothing to add.
    var offersTopUp = false

    /// Where hosts and language versions come from — **`nil` where there are none.**
    ///
    /// Only a portal has any; for Jellyfin and the provider nobody asks. The path
    /// is passed as a closure and not as a source: the sheet should not know `PortalKit`,
    /// it should receive a list.
    ///
    /// *Until just now `netzregeln` stood here — a path into the network sheet that nobody ever
    /// called. The rules are in the sheet itself as switches; the second path was a
    /// declaration of intent.*
    var sources: (@Sendable (String) async throws -> PortalSourceChoice)?

    /// Siehe ``SwiftUI/EnvironmentValues/largeVolumesAcceptable``.
    @Environment(\.largeVolumesAcceptable) private var largeVolumesAcceptable

    init(
        job: DownloadJob, enqueue: @escaping (DownloadJob, Bool) -> Void,
        offersTopUp: Bool = false,
        sources: (@Sendable (String) async throws -> PortalSourceChoice)? = nil
    ) {
        _choice = State(wrappedValue: DownloadChoice(job: job))
        self.enqueue = enqueue
        self.offersTopUp = offersTopUp
        self.sources = sources
    }

    /// Whether the switch is there — **series and first download, both.**
    private var showsQueueNew: Bool {
        offersTopUp && choice.job.extent.episodeCount > 0
    }

    var body: some View {
        ScrollSurface {
            VStack(alignment: .leading, spacing: 0) {
                titleLine

                SectionHeader(title: "stock.scope")
                extents
                // **Why nothing stands here belongs here and not in the builder's
                // head** (finding of 2026-09-09). A column that stays empty in every row
                // reads as a loading error; a sentence below says that the
                // source states no running time and where the real number appears later.
                if choice.isSizeUnknown { Footnote(message: "stock.sizeUnknownWhy") }

                selection

                SectionHeader(title: "stock.rules")
                SwitchRow(
                    title: "stock.wifiOnly", message: "stock.wifiOnlyBody", on: $choice.wifiOnly)
                if showsQueueNew {
                    SwitchRow(
                        title: "stock.topUp", message: "stock.topUpBody", on: $choice.queueNew)
                }
            }
        }
        // **It is asked on appearing and not on building the view.** `/sources` is
        // a fetch via the bridge; putting it in `init` would mean repeating it on every
        // redraw.
        .task {
            guard choice.job.source == .portal, let sources = self.sources else { return }
            choice.sourceChoice = try? await sources(choice.job.id.rawValue)
            // The first row is the default — the same rule by which the bridge takes the first usable
            // host without any input.
            if choice.version.isEmpty { choice.version = choice.variants.first ?? "" }
            if choice.host1.isEmpty {
                choice.host1 = (choice.provider + choice.slots).first ?? ""
            }
        }
        .safeAreaInset(edge: .bottom) { footer }
        // **The suggestion follows the network** (AP6) — but only downwards, and
        // only as long as nobody has chosen. If the job already carries a level, that was
        // a decision, and no rule overrides it.
        //
        // **Here and not in the initialiser:** the environment is not available there yet, and
        // `DownloadChoice` is created as `State` exactly once.
        .task {
            guard choice.job.tier == nil else { return }
            choice.tier = SelectionRule.suggestion(largeVolumesAcceptable: largeVolumesAcceptable)
        }
    }

    private var titleLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: choice.job.title)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)
            if let beside = choice.job.beside {
                Text(verbatim: beside)
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.bottom, MetricsBoard.phone.gutter)
    }

    // MARK: - Umfang

    private var extents: some View {
        ForEach(choice.extents, id: \.self) { extent in
            ChoiceRow(
                name: DownloadChoice.name(forItem: extent),
                number: choice.sizeText(forItem: extent),
                subRow: DownloadChoice.subRow(forItem: extent),
                chosen: choice.extent == extent
            ) { choice.extent = extent }
        }
    }

    // MARK: - The choice per source

    @ViewBuilder
    private var selection: some View {
        switch SelectionRule.forItem(choice.job.source) {
        case .slots(let slots):
            SectionHeader(title: "stock.quality")
            ForEach(slots, id: \.self) { tier in
                ChoiceRow(
                    name: DownloadChoice.name(forItem: tier),
                    number: choice.sizeText(forItem: tier),
                    subRow: DownloadChoice.subRow(forItem: tier),
                    chosen: choice.tier == tier
                ) { choice.tier = tier }
            }
            // **Why it does not say "as good as possible".** The same season in 4K would be
            // 12.4 GB and about nine hours over a mobile cell; on six inches it is
            // indistinguishable from 1080p. The choice must still be visible —
            // otherwise someone makes it by doing nothing.
            Footnote(message: "stock.qualityWhy")

        case .asDelivered:
            SectionHeader(title: "stock.quality")
            // **One version, two reasons** — and they belong apart.
            //
            // With the **provider**, because it holds one stream per title: nobody transcodes,
            // neither the app nor it. With the **Jellyfin server**, because there is one file and
            // every other resolution would first be computed — measured on 2026-09-08: the result
            // is a stream with `Accept-Ranges: none`, and a download over it starts
            // from the beginning after every drop (see ``Downloads/SelectionRule``).
            HintRow(
                icon: Glyph.info.name,
                title: choice.job.source == .jellyfin ? "stock.asFile" : "stock.asDelivered",
                message: choice.job.source == .jellyfin
                    ? "stock.asFileBody" : "stock.asDeliveredBody")
            // **The single connection applies only to the provider.** Its account allows one
            // playback at a time; a Jellyfin server in your own house does not know this limit,
            // and the note would be a warning without a fact behind it there.
            if choice.job.source == .provider {
                HintRow(
                    icon: Glyph.tv.name, color: ColorRole.progress.color,
                    title: "stock.oneConnection", message: "stock.oneConnectionBody")
            }

        case .sourcesAndVersion:
            // **The version first.** It is the decision that cannot be caught up
            // later: resolution annoys on a plane, a wrong audio track makes the title
            // unusable — and choosing again does not work without a network.
            if !choice.variants.isEmpty {
                SectionHeader(title: "stock.language")
                ForEach(choice.variants, id: \.self) { version in
                    ChoiceRow(name: version, chosen: choice.version == version) {
                        choice.version = version
                    }
                }
            }
            // **Host OR levels — never both.** Which two things are offered for choice
            // is decided by the portal: with Animehub they are hosts, with the ARD real
            // resolution levels.
            if !choice.provider.isEmpty {
                SectionHeader(title: "stock.source")
                ForEach(choice.provider, id: \.self) { name in
                    ChoiceRow(name: name, chosen: choice.host1 == name) {
                        choice.host1 = name
                    }
                }
            }
            if !choice.slots.isEmpty {
                SectionHeader(title: "stock.quality")
                ForEach(choice.slots, id: \.self) { name in
                    ChoiceRow(name: name, chosen: choice.host1 == name) {
                        choice.host1 = name
                    }
                }
            }
            if choice.isOnlyBlocked {
                // **The bridge's sentence, verbatim.** "Security check in the browser required"
                // is information, "does not work" would not be.
                ForEach(choice.blockedReasons, id: \.self) { reason in
                    HintRow(
                        icon: Glyph.warning.name, color: ColorRole.progress.color,
                        title: "stock.allBlocked", wording: reason)
                }
            }
            Footnote(message: "stock.resumableWhy")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Separator()
            // **The loud button carries the number that is being decided against.** "Add to
            // downloads" alone would conceal what has just been decided — and the
            // amount is exactly what someone wants to know before a flight.
            Button {
                enqueue(choice.finalizedJob, showsQueueNew && choice.queueNew)
            } label: {
                Text(verbatim: choice.footerCaption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.loud)
            .padding(MetricsBoard.phone.margin)
            .disabled(!choice.finalizedJob.complete)
        }
        .background(.bar)
    }
}
