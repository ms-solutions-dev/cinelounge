import Core
import DesignSystemPhone
import Flows
import ParentalControls
import ProfileKit
import SwiftUI

/// **Manage profiles** — create, change, remove, merge and "start automatically as
/// this profile" (G3, finding B1).
///
/// **Until G3 this worked only on the TV**, and the phone explicitly pointed there. The
/// rules already lived shared there (``Flows/ProfileManagement``); here stands only the thin
/// view on top — the same operations as in `ProfileView` on the TV, in the
/// phone's form: a list, a press opens the operations for a profile.
///
/// **Behind the door `profile`** (``ParentalControls/LockedDoors``): a removed profile
/// takes its state and lock with it. A child profile does not come here at all (decision 20).
/// **A protected profile demands its PIN** — when removing and merging, as on the
/// TV (``Flows/ProfileManagement/RemovalOutcome/pinRequired(_:)``).
struct ManageProfilesView: View {

    let administration: ProfileManagement
    /// Whether a PIN is set on the device — for the hint when creating a child.
    let isPinSet: Bool
    /// After an intervention that affected the active profile — the wrapper updates accounts,
    /// rule and paths (``ShellModel/followProfileChoice()``).
    let afterIntervention: () -> Void

    /// What is currently open.
    enum Sheet: Identifiable {
        case fresh
        case changes(Profile)
        case pin(Profile, Intent)

        var id: String {
            switch self {
            case .fresh: "new"
            case .changes(let profile): "changes-" + profile.identifier.rawValue
            case .pin(let profile, _): "pin-" + profile.identifier.rawValue
            }
        }
    }

    /// What the PIN of a profile is asked for.
    enum Intent {
        case remove(ProfileManagement.RemovalMode)
        case merge(
            leaving: Profile.Identifier, remains: Profile.Identifier, pins: [Profile.Identifier: String])
    }

    @State private var sheet: Sheet?
    /// The profile whose operations are currently open.
    @State private var chosen: Profile?
    @State private var askingToRemove: Profile?
    @State private var choosingPartner: Profile?
    @State private var asksPair: ProfileSync.Pair?
    @State private var startChoice = StartChoice().identifier
    /// Counts interventions, so that the list re-reads after a write to the book.
    @State private var reloadCount = 0
    /// The profiles that lie hidden in iCloud for this device — `nil` as long as
    /// nobody has asked ("Add existing profile").
    @State private var existing: [Profile]?

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    asks

                    SettingsCard(header: "profiles.manage") {
                        ForEach(Array(administration.profile.enumerated()), id: \.element.identifier.rawValue)
                        {
                            slot, profile in
                            if slot > 0 { Separator(isIndented: true) }
                            row(profile)
                        }
                        Separator(isIndented: true)
                        DisclosureRow(
                            title: "profiles.add", icon: Glyph.add.name,
                            isContained: true
                        ) { sheet = .fresh }
                        Separator(isIndented: true)
                        // **Deliberately bring back what was removed here** (2026-09-27) —
                        // ``ProfileKit/ProfileHiding``.
                        DisclosureRow(
                            title: "profiles.addExisting", icon: Glyph.fetchProfile.name,
                            isContained: true
                        ) {
                            Task { existing = await administration.hiddenProfiles() }
                        }
                    }

                    if !administration.canSwitch {
                        Footnote(message: "profiles.singleHint")
                    }
                }
                .padding(.top, MetricsBoard.phone.gutter)
                .id(reloadCount)
            }
        }
        .onAppear {
            administration.load()
            startChoice = StartChoice().identifier
        }
        .confirmationDialog(
            Text(verbatim: chosen?.name ?? ""),
            isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
            titleVisibility: .visible, presenting: chosen
        ) { profile in
            actions(profile)
        }
        // **Removing is a choice** (product requirement 2026-09-27): only here or everywhere.
        // A borrowed profile knows only "Leave share" — its zone belongs to another
        // Apple account (``Flows/ProfileManagement/RemovalMode``).
        .confirmationDialog(
            Text(app: "profiles.removeConfirm"),
            isPresented: Binding(get: { askingToRemove != nil }, set: { if !$0 { askingToRemove = nil } }),
            titleVisibility: .visible, presenting: askingToRemove
        ) { profile in
            if administration.isBorrowed(profile.identifier) {
                Button(role: .destructive) {
                    remove(profile, pin: nil, mode: .everywhere)
                } label: {
                    Text(app: "profiles.leaveShare")
                }
            } else {
                Button(role: .destructive) {
                    remove(profile, pin: nil, mode: .hereOnly)
                } label: {
                    Text(app: "profiles.removeHere")
                }
                Button(role: .destructive) {
                    remove(profile, pin: nil, mode: .everywhere)
                } label: {
                    Text(app: "profiles.removeEverywhere")
                }
            }
            Button(role: .cancel) {
            } label: {
                Text(app: "common.cancel")
            }
        } message: { profile in
            Text(
                app: administration.isBorrowed(profile.identifier)
                    ? "profiles.leaveChoice" : "profiles.removeChoice"
            )
        }
        .confirmationDialog(
            Text(app: "profiles.addExisting"),
            isPresented: Binding(get: { existing != nil }, set: { if !$0 { existing = nil } }),
            titleVisibility: .visible, presenting: existing
        ) { list in
            ForEach(list, id: \.identifier.rawValue) { profile in
                Button {
                    administration.restore([profile])
                    existing = nil
                    reloadCount += 1
                } label: {
                    Text(verbatim: profile.name)
                }
            }
            Button(role: .cancel) {
            } label: {
                Text(app: "common.cancel")
            }
        } message: { list in
            Text(app: list.isEmpty ? "profiles.addExistingNone" : "profiles.addExistingHint")
        }
        .confirmationDialog(
            Text(verbatim: SettingsModel.text("profiles.mergeChoose %@", choosingPartner?.name ?? "")),
            isPresented: Binding(get: { choosingPartner != nil }, set: { if !$0 { choosingPartner = nil } }),
            titleVisibility: .visible, presenting: choosingPartner
        ) { remains in
            ForEach(
                administration.profile.filter { $0.identifier != remains.identifier },
                id: \.identifier.rawValue
            ) {
                other in
                Button(role: .destructive) {
                    merge(leaving: other.identifier, remains: remains.identifier, pins: [:])
                } label: {
                    Text(verbatim: other.name)
                }
            }
            Button(role: .cancel) {
            } label: {
                Text(app: "common.cancel")
            }
        } message: { _ in
            Text(app: "profiles.mergeHint")
        }
        .confirmationDialog(
            Text(app: "profiles.mergeDo"),
            isPresented: Binding(get: { asksPair != nil }, set: { if !$0 { asksPair = nil } }),
            titleVisibility: .visible, presenting: asksPair
        ) { pair in
            Button(role: .destructive) {
                merge(leaving: pair.device, remains: pair.cloud, pins: [:])
            } label: {
                Text(app: "profiles.mergeDo")
            }
            Button(role: .cancel) {
            } label: {
                Text(app: "common.cancel")
            }
        } message: { _ in
            Text(app: "profiles.mergeHint")
        }
        .sheet(item: $sheet) { request in
            content(request)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
                .presentationBackground(ColorRole.surfaceHigh.color)
        }
    }

    // MARK: - The list

    private func row(_ profile: Profile) -> some View {
        let isActive = profile.identifier == administration.active
        return Button {
            chosen = profile
        } label: {
            HStack(spacing: MetricsBoard.phone.gutter) {
                ProfileCircle(
                    letter: profile.initial, avatar: profile.avatar, edge: 34,
                    font: TypeLevel.footer.font, letterColor: ColorRole.reason.color,
                    surface: ProfileColor.tag(profile.color.rawValue) ?? ColorRole.surfaceHigh.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: profile.name)
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.text.color)
                    subRow(profile, isActive: isActive)
                }
                Spacer(minLength: 0)
                Image(systemName: Glyph.next.name)
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Metrics.cardInset)
            .frame(minHeight: Metrics.choiceRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    /// "Here" · "Child" · "Starts automatically" — **shape and word**, not only color.
    private func subRow(_ profile: Profile, isActive: Bool) -> some View {
        var split: [String] = []
        if isActive { split.append(SettingsModel.text("profiles.active")) }
        split.append(SettingsModel.text(profile.kind == .kind ? "profiles.child" : "profiles.adult"))
        if startChoice == profile.identifier { split.append(SettingsModel.text("profiles.startAs")) }
        return Text(verbatim: split.joined(separator: " · "))
            .font(TypeLevel.label.font)
            .foregroundStyle(ColorRole.textQuiet.color)
            .lineLimit(2)
    }

    // MARK: - Open questions "merge?"

    @ViewBuilder
    private var asks: some View {
        let pairs = administration.openQuestions
        if !pairs.isEmpty {
            SettingsCard(header: "profiles.mergeQuestion") {
                ForEach(Array(pairs.enumerated()), id: \.offset) { slot, pair in
                    if slot > 0 { Separator(isIndented: true) }
                    query(pair)
                }
            }
        }
    }

    private func query(_ pair: ProfileSync.Pair) -> some View {
        let here = administration.profile.first { $0.identifier == pair.device }?.name ?? ""
        let there = administration.profile.first { $0.identifier == pair.cloud }?.name ?? ""
        return VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            Text(verbatim: String(format: AppLanguageSetting.text("profiles.mergePair %@ %@"), here, there))
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.text.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: MetricsBoard.phone.gutter) {
                Button {
                    asksPair = pair
                } label: {
                    Text(app: "profiles.mergeDo")
                }
                .buttonStyle(.quiet)
                Button {
                    administration.keepBoth(pair)
                    reloadCount += 1
                } label: {
                    Text(app: "profiles.mergeKeepTwo")
                }
                .buttonStyle(.quiet)
            }
        }
        .padding(Metrics.cardInset)
    }

    // MARK: - The actions for one profile

    @ViewBuilder
    private func actions(_ profile: Profile) -> some View {
        Button {
            sheet = .changes(profile)
        } label: {
            Text(app: "profiles.edit")
        }
        Button {
            let fresh: Profile.Identifier? = startChoice == profile.identifier ? nil : profile.identifier
            StartChoice().set(fresh)
            startChoice = fresh
        } label: {
            Text(app: startChoice == profile.identifier ? "profiles.startAsOff" : "profiles.startAs")
        }
        if administration.canSwitch {
            Button {
                choosingPartner = profile
            } label: {
                Text(app: "profiles.merge")
            }
        }
        if administration.mayRemove(profile.identifier) {
            Button(role: .destructive) {
                askingToRemove = profile
            } label: {
                Text(app: "profiles.remove")
            }
        }
        Button(role: .cancel) {
        } label: {
            Text(app: "common.cancel")
        }
    }

    // MARK: - The sheets

    @ViewBuilder
    private func content(_ request: Sheet) -> some View {
        switch request {
        case .fresh:
            NewProfileView(
                existing: nil, suggestion: administration.nextColor, previousLimit: nil,
                isPinSet: isPinSet, titleInContent: true
            ) { draft in
                administration.save(draft, existing: nil)
                close()
            }
        case .changes(let profile):
            NewProfileView(
                existing: profile, suggestion: profile.color,
                previousLimit: administration.limit(forItem: profile.identifier), isPinSet: isPinSet,
                titleInContent: true
            ) { draft in
                administration.save(draft, existing: profile)
                close(affectsActive: profile.identifier == administration.active)
            }
        case .pin(let profile, let intent):
            PinSheet(
                job: .door(identifier: ProfilePinManagement.door, reason: ""),
                header: .profile(.lock, name: profile.name),
                verifies: { take($0, forItem: profile, intent: intent) },
                sets: { _ in false }, forgotten: nil, succeeded: {})
        }
    }

    private func close(affectsActive: Bool = false) {
        sheet = nil
        reloadCount += 1
        if affectsActive { afterIntervention() }
    }

    // MARK: - Removing and merging

    /// Removed — **if the profile requires a PIN, the sheet asks for it**; a borrowed
    /// profile is left and not buried.
    ///
    /// **And the history goes with it** (on-device test, build 1332, 2026-09-27): it lives in this
    /// package and not in the shared management — ``HistoryStore/forget(profile:)``.
    @discardableResult
    private func remove(
        _ profile: Profile, pin: String?, mode: ProfileManagement.RemovalMode
    ) -> Bool {
        let wasActive = profile.identifier == administration.active
        switch administration.remove(profile.identifier, pin: pin, mode: mode) {
        case .removed:
            Task { await HistoryStore.shared.forget(profile: profile.identifier.rawValue) }
            close(affectsActive: wasActive)
            return true
        case .pinRequired(let shielded):
            guard pin == nil else { return false }
            sheet = .pin(shielded, .remove(mode))
            return false
        case .isBorrowed(let isBorrowed):
            Task {
                try? await administration.leave(isBorrowed.identifier)
                await HistoryStore.shared.forget(profile: isBorrowed.identifier.rawValue)
                close(affectsActive: wasActive)
            }
            return true
        case .impossible:
            return false
        }
    }

    private func merge(
        leaving: Profile.Identifier, remains: Profile.Identifier, pins: [Profile.Identifier: String]
    ) {
        let affects = administration.active == leaving || administration.active == remains
        switch administration.merge(leaving, in: remains, pins: pins) {
        case .pinRequired(let profile):
            sheet = .pin(profile, .merge(leaving: leaving, remains: remains, pins: pins))
        case .merged:
            close(affectsActive: affects)
        case .impossible:
            close()
        }
    }

    /// The typed PIN — **if it is right, it continues; otherwise the sheet stays.**
    private func take(_ pin: String, forItem profile: Profile, intent: Intent) -> Bool {
        switch intent {
        case .remove(let mode):
            return remove(profile, pin: pin, mode: mode)
        case .merge(let leaving, let remains, var pins):
            guard administration.matchesPin(pin, forItem: profile.identifier) else { return false }
            pins[profile.identifier] = pin
            sheet = nil
            merge(leaving: leaving, remains: remains, pins: pins)
            return true
        }
    }
}
