import Core
import DesignSystemPhone
import ProfileKit
import SwiftUI

/// Accounts and servers.
///
/// **A list and not tiles.** Accounts are few and carry no content; a tile wall of three
/// letters would be decoration. What counts here is the distinction — who is signed in,
/// which one is a child account — and that is read in rows.
public struct AccountsView: View {

    /// **Passed in from outside and not built here.** The wrapper holds an account list for the
    /// profile picture and the sheet below it; a second model here would mean that a removal
    /// in Settings does not reach the letter in the circle.
    @State private var model: AccountsModel
    @State private var signOutFor: Account?
    /// Which row has its commands open — at most one.
    @State private var openSwipe: String?
    /// The open "forgot PIN" requests (second review, strand C, finding 6).
    @State private var escapes = PinFallbacks.none

    private let newAccount: () -> Void
    private let migration: () -> Void
    private let certificates: () -> Void
    private let handoff: () -> Void
    /// The profile of an account — for the image and color of the circle in its row (AP49).
    private let profile: (Account.Identifier) -> Profile?
    private let pinReset: () -> Void
    /// Choose an account — **through the wrapper** (``ShellModel/switchAccount(_:)``).
    ///
    /// Until the check evening of 2026-09-25, the row called ``AccountsModel/switchTo(zu:)``
    /// itself: the session jumped over without the parental-controls door, without a profile PIN
    /// and without the profile following. That let a child reach every profile via
    /// Settings → Accounts.
    private let select: (Account) -> Void

    /// - Parameters:
    ///   - profil: **without a default**, so that no call site silently draws the circles
    ///     without an image.
    ///   - waehle: **without a default**, so that no call site switches past the latch.
    public init(
        profile: @escaping (Account.Identifier) -> Profile?,
        select: @escaping (Account) -> Void,
        model: AccountsModel = AccountsModel(),
        newAccount: @escaping () -> Void = {},
        migration: @escaping () -> Void = {},
        certificates: @escaping () -> Void,
        handoff: @escaping () -> Void = {},
        pinReset: @escaping () -> Void = {}
    ) {
        self.pinReset = pinReset
        self.select = select
        _model = State(initialValue: model)
        self.newAccount = newAccount
        self.migration = migration
        self.certificates = certificates
        self.handoff = handoff
        self.profile = profile
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "accounts.title")
                    // **Open requests are at the top**, with a path to the page that confirms
                    // or cancels — they run against a deadline.
                    if !escapes.isEmpty {
                        Button(action: pinReset) {
                            row("accounts.pinResets", character: Glyph.info.name)
                        }
                        .buttonStyle(.plain)
                    }
                    // **`.swipeActions` stood here until 2026-09-06 and did nothing.** It
                    // exists only in a `List`; this list sits in a
                    // ``ScrollSurface``, that is, a `ScrollView`. An account therefore could
                    // not be removed at all — nobody reported it, because
                    // a modifier with no effect is not an error.
                    ForEach(model.accounts) { account in
                        SwipeCommands(
                            pending: $openSwipe, identifier: account.id.stored,
                            commands: [
                                SwipeCommand(
                                    id: "entfernen", title: "accounts.remove",
                                    icon: Glyph.remove.name, kind: .route,
                                    action: { remove(account) })
                            ]
                        ) {
                            AccountRow(
                                account: account, profile: profile(account.id),
                                signedIn: account.id == model.signedIn,
                                swipeMarks: ["accounts.remove"],
                                pinEscape: profile(account.id).flatMap {
                                    escapes.state(forItem: $0.identifier)
                                }
                            ) {
                                select(account)
                            }
                        }
                    }

                    Button(action: newAccount) {
                        row("accounts.add", character: Glyph.login.name)
                    }
                    .buttonStyle(.plain)

                    Divider().overlay(ColorRole.line.color).padding(.vertical, MetricsBoard.phone.gutter)

                    // **Moving and a second server do not sit side by side.** The
                    // difference is the whole screen behind it: whoever moves still has
                    // one server; whoever adds a second has two. A
                    // shared entry would invite taking one for the other.
                    Button(action: migration) {
                        row("accounts.move.change", character: Glyph.server.name)
                    }
                    .buttonStyle(.plain)

                    Button(action: certificates) {
                        row("accounts.certificates", character: Glyph.check.name)
                    }
                    .buttonStyle(.plain)

                    // **The TV is listed here and not under "Appearance".** What is
                    // transferred is credentials — the same kind of thing as the move
                    // one row above, only to a second device instead of a
                    // second server.
                    Button(action: handoff) {
                        row("settings.handover.title", character: Glyph.handoff.name)
                    }
                    .buttonStyle(.plain)

                    Footnote(message: "accounts.footnote")
                        .padding(.top, MetricsBoard.phone.gutter)

                    // **Delete all own iCloud data** (finding 10) — only with the cloud.
                    if ProfileCloud.attached != nil {
                        Divider().overlay(ColorRole.line.color)
                            .padding(.vertical, MetricsBoard.phone.gutter)
                        CloudDataSection()
                    }
                }
            }
        }
        .task { await loadFallbacks() }
        .onReceive(NotificationCenter.default.publisher(for: .pinEscape)) { _ in
            Task { await loadFallbacks() }
        }
        .sheet(item: $signOutFor) { account in
            SignOutSheet(
                account: account,
                signOut: {
                    model.remove(account)
                    signOutFor = nil
                },
                cancel: { signOutFor = nil }
            )
            .presentationDetents([.fraction(SheetID.signOut.portion), .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
            .presentationBackground(ColorRole.surfaceHigh.color)
        }
    }

    /// **Only the last account asks.** As long as a second one exists, removing is
    /// one entry fewer and not a cleanup — a warning would then be a threat without
    /// cause.
    private func loadFallbacks() async {
        escapes = await PinFallbacks.read(
            cloud: ProfileCloud.attached, ledgerStore: FileStore())
    }

    private func remove(_ account: Account) {
        if model.isLast(account) {
            signOutFor = account
        } else {
            model.remove(account)
        }
    }

    private func row(_ title: String, character: String) -> some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            Image(systemName: character)
                .foregroundStyle(ColorRole.textMatt.color)
                .frame(width: 22)
            Text(appKey: title)
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.text.color)
            Spacer(minLength: 0)
            Image(systemName: Glyph.next.name)
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textQuiet.color)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .frame(minHeight: Metrics.choiceRow)
        .contentShape(Rectangle())
    }
}
