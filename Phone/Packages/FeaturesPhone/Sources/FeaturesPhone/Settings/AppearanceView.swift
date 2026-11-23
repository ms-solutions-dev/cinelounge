import Core
import DesignSystemPhone
import Diagnose
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// Area 6 · Appearance — language, color scheme and app icon.
///
/// **The language is chosen in the app and not only in the system.** Whoever runs their phone in German
/// and watches films in Turkish has a reason for it; pointing them to the
/// system settings would mean switching the whole interface to change one
/// area.
///
/// **Three schemes, and each had to pass the contrast computation.** `Contrast` runs every
/// combination of the board through the thresholds 4.5 : 1 and 3 : 1 — a scheme that merely
/// looks different does not even get in here. That is why the list is short and will
/// stay so.
///
/// **The third section is a choice that already existed and that nobody
/// could make.** From E35 there are four drafts of the app icon; the chosen one is on the
/// Home Screen, the other three lay only in the comparison image. Together they cost about
/// 100 kilobytes in the bundle — that is the whole price for this choice not lying once and for
/// all with the builder.
///
/// **Three cards instead of three dividers (2026-09-07).** The three sections hung on
/// `Divider()` rows on the bare background — the same form that made the root
/// look "stiff and old-fashioned", only one level deeper. The own ``choiceRow`` has
/// been dropped in the process: ``ChoiceRow`` has long existed and draws the same checkmark.
struct AppearanceView: View {
    @Environment(\.horizontalSizeClass) private var widthClass

    /// The choice **of the active profile** (AP46) — no longer `@AppStorage`, because it lives in the
    /// Keychain per profile. A language switch rebuilds the interface
    /// (``DesignSystemPhone/LanguageState``), and it is read anew here in the process.
    @State private var language = LanguageChoice.chosen()

    /// Whether the choice only takes effect at the next start — measured against the **running bundle**.
    @State private var needsRestart = false
    /// The device's choice — **from the one store** (``Core/ColorPattern``, AP58 R7); until
    /// then `@AppStorage`, while the TV and the handoff used the Keychain.
    @State private var patterns = ColorPattern.chosen() ?? ColorBoard.phoneCinema.id

    #if canImport(UIKit)
        /// Which icon is on the Home Screen. `nil` is the main icon.
        ///
        /// **Held and not asked on every draw.** `alternateIconName` would be the
        /// more honest source, but it only becomes true *after* the system notice; a checkmark
        /// that sticks to the old entry for half a second looks as if the press
        /// had not counted. On failure the value therefore explicitly goes back.
        @State private var symbol: String?
    #endif

    private let arrangeShelves: () -> Void

    init(arrangeShelves: @escaping () -> Void = {}) {
        self.arrangeShelves = arrangeShelves
    }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    languageCard

                    // **The honest price, and it only stands there when it applies.**
                    // Since 2026-09-25 (AP46) a chosen language applies immediately — every
                    // `String(localized:)` site reads ``Core/AppLanguageSetting/bundles``. What remains
                    // is the return to "System": iOS formed the system language at
                    // start, and it only takes effect at the next one.
                    if needsRestart {
                        HintRow(
                            icon: Glyph.info.name, color: ColorRole.progress.color,
                            title: "settings.look.restart")
                    }

                    // **And the second path has to be mentioned.** Since 13, iOS keeps a
                    // language per app in the system settings; it is the same switch.
                    // An app that acts as if it were the only place lets the
                    // viewer find the contradiction themselves.
                    //
                    // **Language and color scheme travel along** — ``SetupBundle``
                    // lists both explicitly. The origin is stated once here and not
                    // at each of the seven rows above and below.
                    Footnote(message: "settings.look.systemLanguage")
                        .origin(.handoff)
                        .padding(.bottom, MetricsBoard.phone.section)

                    patternCard

                    #if canImport(UIKit)
                        iconCard
                    #endif

                    // **A card without a heading, and that is the rule from
                    // ``SettingsCard``:** a head that repeats its only row
                    // says nothing — the same finding as on the simulator with
                    // "Report channel or title".
                    SettingsCard {
                        DisclosureRow(
                            title: "settings.look.shelves", icon: Glyph.sorting.name,
                            isContained: true, action: arrangeShelves)
                    }

                    Footnote(message: "settings.look.footnote")
                }
                .contentColumn(widthClass)
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
        .onAppear { needsRestart = LanguageChoice.needsRestart() }
    }

    // MARK: - Sprache

    private var languageCard: some View {
        SettingsCard(header: "settings.language") {
            ForEach(Array(LanguageChoice.isOffered.enumerated()), id: \.element.identifier) {
                slot, entry in
                if slot > 0 { Separator() }
                ChoiceRow(name: entry.name, chosen: language == entry.identifier) {
                    // **Through ``LanguageChoice`` and not through `@AppStorage` alone.** The
                    // choice has to go into **two** stores: its own, which travels in the handoff
                    // bundle, and `AppleLanguages`, which decides what the bundle
                    // looks up. Until 2026-09-07 only the first stood there — and nobody read
                    // it.
                    LanguageChoice.set(entry.identifier)
                    language = entry.identifier
                    needsRestart = LanguageChoice.needsRestart()
                }
            }
        }
    }

    // MARK: - Farbmuster

    private var patternCard: some View {
        SettingsCard(header: "settings.theme") {
            ForEach(Array(ColorBoard.all(forItem: .phone).enumerated()), id: \.element.id) { slot, board in
                if slot > 0 { Separator() }
                ChoiceRow(
                    name: SettingsModel.text(board.nameKey),
                    chosen: patterns == board.id
                ) {
                    patterns = board.id
                    ColorPattern.select(board.id)
                    ColorBoard.current = board
                }
            }
        }
    }

    // MARK: - App-Symbol

    #if canImport(UIKit)

        /// The third section — the same form as the color schemes, only with an image.
        ///
        /// **`@MainActor` all the way down to ``select(_:)``.** `UIApplication` is bound to the
        /// main actor; without the annotation the binding from ``body``
        /// does not reach into a helper view of its own, and the compiler rejects the call.
        @ViewBuilder @MainActor
        private var iconCard: some View {
            SettingsCard(header: "settings.icon") {
                ForEach(Array(IconRow.choice.enumerated()), id: \.offset) { slot, identifier in
                    if slot > 0 { Separator() }
                    IconRow(identifier: identifier, chosen: symbol == identifier) {
                        select(identifier)
                    }
                }
            }
            // **It is asked on appearing and not on every draw.** Whoever comes back from the
            // system settings finds the checkmark where the icon
            // really is.
            .onAppear { symbol = UIApplication.shared.alternateIconName }

            Footnote(message: "settings.look.icon.footnote")
                .padding(.bottom, MetricsBoard.phone.section)
        }

        /// Switches the icon — **and takes the checkmark back if iOS declines.**
        ///
        /// `setAlternateIconName` fails if the name is not in the bundle or
        /// the system does not currently allow the switch. Without the rollback the checkmark would stand
        /// at an icon that is not on the Home Screen at all — the view
        /// would then claim something that a look at the Home Screen refutes.
        ///
        /// **The notice "The icon change was made" is NOT rebuilt.** iOS
        /// shows it on its own; one of our own next to it would be the same sentence twice.
        @MainActor
        private func select(_ identifier: String?) {
            guard identifier != symbol else { return }
            let previous = symbol
            symbol = identifier
            Task {
                do {
                    try await UIApplication.shared.setAlternateIconName(identifier)
                } catch {
                    Diagnose.hint(.surface, "App icon not switched", error)
                    symbol = previous
                }
            }
        }
    #endif
}

#if canImport(UIKit)

    /// A row of the icon choice — checkmark, icon image, name.
    ///
    /// **Not ``ChoiceRow``, although it looks almost the same.** A color scheme can be
    /// named, a glyph cannot: "Arc" and "Negative" say nothing to a viewer
    /// who has never seen the comparison image. The choice here is made by **appearance**,
    /// so the appearance stands in the row.
    ///
    /// **And it is a view of its own and not a helper function of the parent view
    /// (2026-09-07).** The indent comes from the environment, and the environment only reaches whose
    /// `body` is evaluated **inside** the card. A row that the parent view
    /// assembles itself would read the value from outside there — 20 instead of 14, and the row
    /// would stand six points off from all the others in the card.
    struct IconRow: View {

        /// `nil` is the main icon.
        let identifier: String?
        let chosen: Bool
        let action: () -> Void

        @Environment(\.rowInset) private var inset

        /// How large an icon stands in the row — 44 points, the target size.
        private static let edge: CGFloat = 44

        /// The choice: `nil` for the main icon, then the alternate icons of the bundle.
        static var choice: [String?] { [nil] + alternateIcons }

        /// What the alternate icons are called — **read from the bundle, not maintained here.**
        ///
        /// `scripts/appsymbol.py --switchObserver` writes the loose PNGs and these entries in
        /// one go. A second list in the source would be exactly the place where the two
        /// drift apart — and a name that the bundle does not know only shows up on the device
        /// when the switch fails.
        ///
        /// **Sorted, because a dictionary has no order.** Without it the
        /// list would be in a different order at every start.
        static var alternateIcons: [String] {
            guard
                let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons")
                    as? [String: Any],
                let all = icons["CFBundleAlternateIcons"] as? [String: Any]
            else { return [] }
            return all.keys.sorted()
        }

        var body: some View {
            Button(action: action) {
                HStack(spacing: MetricsBoard.phone.gutter) {
                    Image(systemName: Glyph.done.pair.outlined)
                        .iconSize(13, weight: .semibold)
                        .foregroundStyle(ColorRole.brandLight.color)
                        // **The checkmark is there for the eye.** For the screen reader
                        // ``AccessibilityTraits/isSelected`` says the same — and in the
                        // language in which a viewer expects it.
                        .opacity(chosen ? 1 : 0)
                        .frame(width: 15)
                        .accessibilityHidden(true)
                    image
                    Text(appKey: "settings.look.icon.\(identifier ?? "main")")
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.text.color)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, inset)
                .frame(minHeight: Metrics.choiceRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(chosen ? [.isSelected] : [])
        }

        /// The icon in the rounding that iOS gives it on the Home Screen.
        ///
        /// **The same factor 0.2237 as in `scripts/appsymbol.py`.** The delivered PNGs
        /// are square and unrounded, because iOS masks them itself; shown unrounded
        /// it would be an image that never appears like that on any screen.
        private var image: some View {
            let corner = RoundedRectangle(cornerRadius: Self.edge * 0.2237, style: .continuous)
            return Group {
                if let found = Self.image(identifier) {
                    Image(uiImage: found).resizable()
                } else {
                    ColorRole.surfaceHigh.color
                }
            }
            .frame(width: Self.edge, height: Self.edge)
            .clipShape(corner)
            .overlay(corner.strokeBorder(ColorRole.lineQuiet.color, lineWidth: 0.5))
            .accessibilityHidden(true)
        }

        /// The image for an icon name. `nil` is the main icon.
        ///
        /// **The main icon lives in the asset catalog, and it does not hand itself out under its
        /// catalog name.** `actool` additionally puts it into the bundle as a loose file
        /// and writes its name to `CFBundlePrimaryIcon`; from there it is
        /// fetched. `AppIcon60x60` is the fallback — an empty frame would be the worse
        /// information compared with a second-hand name.
        private static func image(_ identifier: String?) -> UIImage? {
            guard let identifier else { return UIImage(named: primaryIconFile) }
            return UIImage(named: "symbol-\(identifier)")
        }

        private static var primaryIconFile: String {
            guard
                let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons")
                    as? [String: Any],
                let main = icons["CFBundlePrimaryIcon"] as? [String: Any],
                let files = main["CFBundleIconFiles"] as? [String], let last = files.last
            else { return "AppIcon60x60" }
            return last
        }
    }
#endif
