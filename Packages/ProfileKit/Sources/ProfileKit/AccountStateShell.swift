import Core
import Foundation

extension AccountState {

    /// The same information from the ``ProfileBook`` — **the wrapper from AP41, row 6.**
    ///
    /// **Why the old types stay for one release.** ``AccountState`` is read in about a dozen
    /// places, ``AppSidebar`` and ``MainView`` included, and ``AccountState/Area`` decides which
    /// area is the start. Rewriting all of them in one day would mean checking the model
    /// rewrite and the UI rewrite in a single step — and if something is missing afterwards,
    /// nobody knows which of the two it was. The wrapper separates them: from here on the
    /// answer comes from the book, and the views notice nothing.
    ///
    /// **What the wrapper does not save:** ``AccountState/load(from:)`` still reads the
    /// **device state** from the Keychain. It disappears when the last call site points to
    /// the book; until then it is the fallback for a device that has no profile yet.
    public init(_ state: ProfileBook.Situation) {
        self.init(
            hasJellyfin: state.hasMediaServer,
            hasPlaylist: state.hasChannelList,
            hasPortals: state.wantsPortals)
    }
}

extension ProfileBook {

    /// The information for the views that still speak ``AccountState``.
    public var accountState: AccountState { AccountState(state) }
}
