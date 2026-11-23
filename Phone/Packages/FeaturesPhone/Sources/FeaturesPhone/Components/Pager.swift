import SwiftUI

/// A horizontally swipeable stack of which exactly one is always visible — **in a loop**.
///
/// **Why `TabView` and no custom gesture:** it brings the rubber band at the end, following
/// along during the drag, the snapping and the screen-reader support. A rebuilt `DragGesture`
/// would have none of that and would be the third place in the project where a system
/// behavior is imitated by hand.
///
/// **The ring** (requirement of 2026-09-05: swiping past the end of the hero must allow
/// continuing in the same direction). `TabView` knows no wraparound; at the last element it
/// springs back, and that reads like a lock. The way out is as old as image carousels: the
/// stack gets a copy of the last element at the front and one of the first at the back.
/// Whoever swipes over the edge lands on a copy — and as soon as the snapping is over, it is
/// **silently** switched to the real counterpart. For the thumb there is nothing to see: both
/// sides show the same image.
///
/// **The switching needs the waiting time.** Without it, it falls into the middle of the
/// running animation and aborts it — visible as a jolt. 350 milliseconds is the duration
/// `TabView` takes for snapping.
///
/// **Why the platform switch is here and not in the view:** `page` does not exist on macOS,
/// and macOS is built in this project only so that `swift test` runs on the Mac instead of in
/// the simulator — feedback in seconds instead of minutes. The switch therefore belongs in
/// exactly one place; every view that writes `#if os` itself is one more place where the two
/// branches can drift apart.
struct Pager<Element: Identifiable, Content: View>: View {

    let elements: [Element]
    /// The real position from 0 to `elements.count - 1` — what counts on the outside.
    @Binding var settled: Int
    let height: CGFloat
    @ViewBuilder let content: (Element) -> Content

    /// The position in the ring from 0 to `elements.count + 1`.
    @State private var inLoop = 1

    private var loopMath: Wreath { Wreath(count: elements.count) }

    /// This is how long the snapping lasts before a silent switch is allowed.
    private static var snapDuration: Duration { .milliseconds(350) }

    var body: some View {
        #if os(iOS)
            TabView(selection: $inLoop) {
                ForEach(loop, id: \.location) { slot in
                    content(slot.element).tag(slot.location)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: height)
            .onChange(of: inLoop) { _, fresh in
                let real = loopMath.state(zu: fresh)
                if settled != real { settled = real }
                if loopMath.isCopy(fresh) { switchSilently(from: fresh) }
            }
            .onChange(of: settled) { _, fresh in
                let target = loopMath.nextPosition(from: inLoop, zu: fresh)
                if target != inLoop { inLoop = target }
            }
            .onAppear { inLoop = loopMath.location(zu: settled) }
        #else
            // Without swiping: on the Mac only the tests run, and they test the content and not the
            // gesture.
            if elements.indices.contains(settled) {
                content(elements[settled]).frame(height: height)
            }
        #endif
    }

    private struct Slot: Identifiable {
        let location: Int
        let element: Element
        var id: Int { location }
    }

    /// The stack with the two copies at the edges.
    private var loop: [Slot] {
        guard let first = elements.first, let last = elements.last else { return [] }
        return [Slot(location: 0, element: last)]
            + elements.enumerated().map { Slot(location: $0.offset + 1, element: $0.element) }
            + [Slot(location: elements.count + 1, element: first)]
    }

    /// After snapping, jumps to the real counterpart of the edge copy.
    private func switchSilently(from loopIndex: Int) {
        let target = loopMath.realCounterpart(zu: loopIndex)
        Task { @MainActor in
            try? await Task.sleep(for: Self.snapDuration)
            guard inLoop == loopIndex else { return }
            var withoutMotion = Transaction()
            withoutMotion.disablesAnimations = true
            withTransaction(withoutMotion) { inLoop = target }
        }
    }

}
