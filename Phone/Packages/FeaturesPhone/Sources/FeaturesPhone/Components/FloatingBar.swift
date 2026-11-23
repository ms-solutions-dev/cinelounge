import DesignSystemPhone
import SwiftUI

/// The bar above the tab bar.
///
/// It sits 83 points above the edge and is 78 tall — both consequences of the thumb
/// limit: From y ≥ 560 the thumb reaches, and everything that is pressed often belongs
/// below that. **Without exception.** The home screen had one — the Continue Watching
/// button stood at y = 330, justified by a floating bar being "reserved for the detail
/// page". Home and detail page are never visible at the same time; there was nothing
/// to reserve.
struct FloatingBar<Content: View>: View {

    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            content
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .frame(height: Metrics.floatingBar)
        .frame(maxWidth: .infinity)
        .background(Material.chromeBar)
        .edge()
        .padding(.bottom, Metrics.floatingBarBottom - Metrics.floatingBar)
    }
}
