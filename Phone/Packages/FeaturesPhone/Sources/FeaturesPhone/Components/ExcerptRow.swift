import DesignSystemPhone
import Flows
import SwiftUI

/// The chip row above a catalog — **state filters and nothing else.**
///
/// **What no longer stands here, and why.** The design showed five chips that belonged to
/// three different kinds: "All" (reset), "Movies 98" and "Series 23" (**catalog
/// replacement**), "Recently added" (**sort order**) and "In progress 6" (filter). One of the
/// number carriers did not change the set when pressed but the order.
///
/// * **Movies and series have been separate catalogs since AP11** with their own register
///   row. A chip that replaces a catalog is the same mistake as a tab that does it.
/// * **"Recently added" is a sort order** and belongs in the ⋯ sheet. A sort order disguised
///   as a filter produces exactly the mixed grammar that this row dissolves.
///
/// **No chip carries a number**, and that is not frugality. The catalog count is cheap
/// (`ContentSource.itemCount`, a round trip without payload) and appears in the status line.
/// The **state counts** are not: `Core.ItemFilter` carries `searchTerm`, `kinds`, `sortBy`,
/// `ascending` and `limit` — **no field for watched, in progress or favorite**. "Unwatched
/// 47" arises only once the whole list is there; with a category of 4,812 titles that means:
/// after the tunnel. A number that arrives later changes the chip width, and the row moves
/// away under the thumb.
///
/// The rule behind it is one and not an enumeration: **numbers belong to the catalog, chips
/// belong to the view of it.**
struct ExcerptRow: View {

    let possible: [CatalogSlice]
    let chosen: CatalogSlice?
    let select: (CatalogSlice?) -> Void

    var body: some View {
        // A switch with one side is not a switch: if only "All" remains, the row is dropped entirely
        // instead of showing a button that can change nothing.
        if !possible.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metrics.targetSpacing) {
                    Chip(title: "common.all", on: chosen == nil) { select(nil) }
                    ForEach(possible) { slice in
                        Chip(title: slice.titleKey, on: chosen == slice) {
                            select(chosen == slice ? nil : slice)
                        }
                    }
                }
                .padding(.horizontal, MetricsBoard.phone.margin)
            }
        }
    }
}
