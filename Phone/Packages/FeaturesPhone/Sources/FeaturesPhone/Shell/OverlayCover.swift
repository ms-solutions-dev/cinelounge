import SwiftUI

extension View {

    /// Lays a view over everything as a full screen — also over the tab bar.
    ///
    /// On iOS this is `fullScreenCover`. That does not exist on macOS, and this package
    /// also builds there: **not** because the app is ever meant to run on a Mac, but
    /// so that `swift test` runs on the Mac and answers in seconds instead of in minutes
    /// in the simulator. For this one purpose a sheet suffices.
    @ViewBuilder
    func overlay(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        #if os(iOS)
            fullScreenCover(isPresented: isPresented, content: content)
        #else
            sheet(isPresented: isPresented, content: content)
        #endif
    }
}
