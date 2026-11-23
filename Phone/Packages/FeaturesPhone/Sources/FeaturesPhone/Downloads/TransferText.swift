import Downloads

/// Which sentence belongs to which state of a transfer.
///
/// **A place of its own and not a static member of the row** — the row is a `View`,
/// and `View` is bound to the main actor; **including its static members.** A check
/// that wants to prove the mapping without a view crashes there, with a
/// crash report instead of a failure (`_swift_task_checkIsolatedSwift`). Exactly that
/// happened on 2026-09-08.
///
/// **`@MainActor`, because ``CaptionLabel/readable`` is** — and that is no step backwards
/// from the reason this type came about. That was that `View` binds its
/// static members along and a check **crashes** there instead of failing.
/// Here the binding is explicitly on the type; a check writes `@MainActor` in front
/// and gets a failure when something is wrong, not a crash report.
///
/// **The statement is no matter of view anyway.** Which sentence belongs to "paused because of
/// mobile data" is a decision about information; how it looks is decided by
/// the row.
@MainActor
enum TransferText {

    /// **A ``CaptionLabel`` and not a finished string.** Under `swift test` there is
    /// no app bundle, and `String(localized:)` returns the **key** instead of the
    /// text; a check for German words would thus check the presence of the catalog
    /// and not the statement.
    static func message(forItem transfer: Transfer) -> CaptionLabel {
        switch transfer.state {
        case .isLoading:
            // Composed, i.e. a wording — two amounts side by side are
            // nothing that would be translated.
            //
            // **And behind it the time of day, as soon as it is known.** That is the number the
            // whole travel idea is about: ten gigabytes are, on the two
            // cells this project has measured, once three hours and once
            // thirty-eight — the difference is a change of location. A bar shows the same for
            // both.
            .wording(
                "\(DownloadsModel.members(transfer.loaded)) / "
                    + "\(DownloadsModel.members(transfer.total))"
                    + (completionText(transfer) ?? ""))
        case .idle(let reason):
            reason.map { reasonText($0) } ?? .key("stock.paused")
        case .waitingForConnection: .key("stock.waitingForConnection")
        case .failed(let error): loadText(error)
        case .done: .key("stock.done")
        }
    }

    /// **Every download error carries its own sentence — with the next step.**
    ///
    /// The rule stands verbatim at ``Downloads/LoadError`` since the type exists: *"A
    /// common error message would be particularly expensive here: 'Not resumable' demands
    /// a different host, 'different file' demands a fresh start, and 'no space'
    /// demands clearing up. Hiding three different next steps behind one warning triangle
    /// is exactly half the build."*
    ///
    /// **It is only fulfilled on 2026-09-09** Until then `.wording(message)` stood here, and the
    /// sentence was filled with `"\(error)"` — on the simulator that produced, under "Floupruk Saisjo
    /// piki beflund Leglaut'm Cosler", a red `network("CancellationError()")`. Swift internals
    /// under a warning triangle are the worst of the three possibilities: they look
    /// like a defect of the app, name no way forward and cannot be translated.
    ///
    /// **The raw text is not gone with that.** It is in the diagnostics, where it belongs —
    /// ``DownloadsManager`` writes it one line before setting the state.
    /// One sentence per refusal — **and none of them says "Connection lost".**
    ///
    /// **The requirement of 2026-09-09:** check whether general formats were forgotten
    /// so that it does not show up on every single attempt.
    /// That is exactly what this enumeration is for: the next unknown host
    /// lands in a **named** case, and the viewer reads what was delivered
    /// instead of a guess about their network.
    ///
    /// **Two of them go away by themselves** — ``Downloads/DeliveryKind/Rejection/accessBusy``
    /// (the provider account allows one connection) and ``…/liveWithoutEnd`` (later yes,
    /// now no). The other six never. The difference belongs in the sentence, because it
    /// decides whether "Try again" makes sense.
    static func declineText(_ reason: DeliveryKind.Rejection) -> CaptionLabel {
        switch reason {
        case .dash: .key("stock.errorDash")
        case .endlessStream: .key("stock.errorEndlessStream")
        case .liveWithoutEnd: .key("stock.errorLiveNoEnd")
        case .rightsManagement: .key("stock.errorDrm")
        case .encrypted: .key("stock.errorEncrypted")
        case .unknownFormat: .key("stock.errorUnknownFormat")
        case .emptyList: .key("stock.errorEmptyList")
        case .accessBusy: .key("stock.errorAccountBusy")
        case .noAddress: .key("stock.errorNoAddress")
        }
    }

    static func loadText(_ error: LoadError) -> CaptionLabel {
        switch error {
        // **"Version" and not "host".** Fallback happens by itself
        // (``AddressProvider/fallBack()``); when this sentence appears, **none** of the
        // hosts answered ranges. The last remaining way is a different
        // language version or level, and that is in the download sheet.
        case .notResumable: .key("stock.errorNoResumableSource")
        case .differentFile: .key("stock.errorOtherFile")
        case .corrupted: .key("stock.errorDamaged")
        case .noSpace: .key("stock.errorNoSpace")
        // **Paused is not an error**, and this case should not reach the row at all
        // — ``DownloadsManager`` catches it. If it is here anyway, the
        // honest sentence is the same as when pausing by hand.
        case .wasCancelled: .key("stock.paused")
        case .network: .key("stock.errorNetwork")
        case .notReady: .key("stock.errorNotReady")
        // **What was delivered, and why there is no way for it** (2026-09-09). Until then
        // every unknown delivery was called "Connection lost" — and the viewer
        // faced a sentence that pointed in the wrong direction: the network was fine,
        // the **format** was a different one. The eight reasons are at ``Downloads/DeliveryKind/Rejection``,
        // each with the measurement it comes from.
        case .notLoadable(let reason): declineText(reason)
        }
    }

    /// " · done about 04:20" — **`nil` as long as the line is unmeasured.**
    ///
    /// **An invented time of day would be worse than none**, because it looks like a
    /// measurement. It is measured by the download itself, block by block; before the first
    /// nobody knows, and then nothing stands there.
    static func completionText(_ transfer: Transfer) -> String? {
        guard let done = transfer.finishesAt() else { return nil }
        let clockTime = done.formatted(date: .omitted, time: .shortened)
        return " · " + CaptionLabel.key("stock.doneAround").readable + " " + clockTime
    }

    /// **Every reason carries its own sentence** — "Paused, you are on mobile data" is
    /// information with a way next to it, "Error" would be a dead end.
    static func reasonText(_ reason: NetworkRule.Reason) -> CaptionLabel {
        switch reason {
        case .noNetwork: .key("stock.pausedNoNetwork")
        case .cellular: .key("stock.pausedCellular")
        case .expensive: .key("stock.pausedExpensive")
        case .frugal: .key("stock.pausedLowData")
        }
    }
}
