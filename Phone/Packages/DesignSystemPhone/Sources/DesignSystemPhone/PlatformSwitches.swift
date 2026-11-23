import SwiftUI

extension View {

    /// An input field that does not capitalize and does not autocorrect.
    ///
    /// **With a platform switch, because `textInputAutocapitalization` does not exist on macOS**
    /// — and macOS is built here only so that `swift test` runs on the Mac instead of in the
    /// simulator. The switch lives in this one place; every view that writes `#if os` itself is
    /// one more place where the branches drift apart.
    ///
    /// **Why both together:** whoever types a genre name or a film title otherwise gets "Kriegs"
    /// capitalized and "Badausjus" "corrected" to "Nauru" — and both hit a search that compares by
    /// characters.
    public func asSearchTerm() -> some View {
        #if os(iOS)
            textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
            autocorrectionDisabled()
        #endif
    }
}

extension View {

    /// A screen that shows only the film.
    ///
    /// **With a platform switch, because `statusBarHidden` does not exist on macOS** — and macOS
    /// is built here only so that `swift test` runs on the Mac instead of in the simulator. The
    /// switch lives in this one place; every view that writes `#if os` itself is one more place
    /// where the branches drift apart.
    public func movieOnly() -> some View {
        #if os(iOS)
            statusBarHidden().persistentSystemOverlays(.hidden)
        #else
            self
        #endif
    }
}

extension View {

    /// A screen title in the narrow form.
    ///
    /// **With a platform switch, because `navigationBarTitleDisplayMode` does not exist on
    /// macOS** — and macOS is built here only so that `swift test` runs on the Mac instead of in
    /// the simulator. The switch lives in this one place; every view that writes `#if os` itself
    /// is one more place where the branches drift apart.
    ///
    /// **Narrow and not large, and that is a decision** (2026-09-07): a large title costs 96 points
    /// above the thumb limit. `GESTALTUNG.md` §2 reserves ``Styling/TypeLevel/lead``
    /// for the title of a page **on opening** — a settings area is not opened to be looked at but
    /// to be operated.
    public func narrowTitle() -> some View {
        #if os(iOS)
            navigationBarTitleDisplayMode(.inline)
        #else
            self
        #endif
    }

    /// A `List` in the same card shape that ``SettingsCard`` draws by hand.
    ///
    /// **Why a `List` and not a card (2026-09-07).** Five of the six sub-screens were switched to
    /// cards on that day; the group list is the exception, for a reason that outweighs
    /// appearance: items are **dragged** here. `onMove` with drag handle and edit mode exists
    /// only in a `List` — a rebuilt drag gesture in a `ScrollSurface` would trade a working system
    /// gesture for a custom one, and that for 79 groups.
    ///
    /// **So the shape of the card instead of the card itself.** `insetGrouped` draws exactly
    /// that: inset sections with rounding on the background. The price is that the light edge is
    /// missing — it lives in ``edge()`` and cannot be handed to a system list.
    ///
    /// **The switch lives here and not in the view** — the same rule as for ``narrowTitle()``:
    /// `insetGrouped` does not exist on macOS, and macOS is only built so that `swift test` runs
    /// on the Mac.
    public func cardList() -> some View {
        #if os(iOS)
            listStyle(.insetGrouped)
        #else
            listStyle(.plain)
        #endif
    }
}
