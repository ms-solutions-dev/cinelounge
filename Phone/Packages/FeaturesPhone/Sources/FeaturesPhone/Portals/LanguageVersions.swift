import DesignSystemPhone
import PortalKit
import SwiftUI

/// DE, JA, OmU — the language versions of a title.
///
/// **With an anime the version is half the choice.** "Ceitfrougrai in German" and "Ceitfrougrai
/// in the original with subtitles" are two different evenings for the viewer; a
/// portal that conceals the choice and takes any is wrong in half of the
/// cases.
///
/// **Not on the tile, but here.** The design draws the marks on the poster too.
/// They would come there for nothing — `BridgeReply.ContentEntryRecord` already carries `languages`
/// along —, but the path there goes through `Core.MediaItem`, and that has no field for it.
/// Adding one would mean changing the type on which the whole TV app stands, for
/// a mark. The **choice** is the substance, and it stands here in full.
struct LanguageVersions: View {

    let variants: [String]
    let chosen: String?
    let select: (String) -> Void

    var body: some View {
        // A single version is no choice — then the row is dropped, instead of showing a
        // button that can change nothing.
        if variants.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metrics.targetSpacing) {
                    ForEach(variants, id: \.self) { version in
                        Chip(wording: Self.tag(version), on: version == chosen) {
                            select(version)
                        }
                    }
                }
                .padding(.horizontal, MetricsBoard.phone.margin)
            }
        }
    }

    /// The mark for a version — **shared** (``PortalKit/LanguageTag/short(_:)``).
    nonisolated static func tag(_ version: String) -> String {
        LanguageTag.short(version)
    }
}
