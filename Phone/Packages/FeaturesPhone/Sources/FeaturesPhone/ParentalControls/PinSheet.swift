import DesignSystemPhone
import ParentalControls
import SwiftUI

/// Sheet: enter PIN.
///
/// Four dots, keypad in the lowest third. **The header says WHAT FOR it is currently
/// asking** — one sentence of its own per door. "To switch to another account" when changing the
/// PIN would be the wrong information, and wrong information in front of a lock is worse
/// than none at all.
///
/// **The stages and their rules have lived in ``ParentalControls/PinEntry`` since AP58 R2** —
/// the same as on the TV; here it only says how the phone shows them.
///
/// **Three stages, and which comes first is told by the request.** Whoever *checks* a PIN types
/// once; whoever *assigns* one types twice (otherwise a typo is a locked app);
/// whoever *changes* it types three times — the old one first, because a PIN that can be changed without the old one
/// is superfluous at the moment someone wants to change it.
///
/// **No counter and no lock after three wrong attempts.** From the market it is established
/// that all the work is in *leaving*; a waiting lock hits first the
/// parent who mistypes in the dark. The escape is explicitly there instead
/// (``PinForgottenView``), and the PIN applies only to this phone — more severity here
/// would not be more security, only more annoyance.
struct PinSheet: View {

    let job: PinTask

    /// What stands above the keypad, per stage — see ``PinHeader``.
    let headerSentences: PinHeader

    /// Checks an existing PIN.
    let verifies: (String) -> Bool

    /// Sets a new one.
    let sets: (String) -> Bool

    /// The path to the account password — missing where there is nothing yet to forget.
    var forgotten: (() -> Void)?

    /// The PIN was correct or was set.
    let succeeded: () -> Void

    @State private var digits = ""
    @State private var input: PinEntry
    @State private var wrong = false
    @State private var report: String?

    init(
        job: PinTask, verifies: @escaping (String) -> Bool,
        sets: @escaping (String) -> Bool, forgotten: (() -> Void)? = nil,
        succeeded: @escaping () -> Void
    ) {
        self.init(
            job: job, header: .forItem(job), verifies: verifies, sets: sets,
            forgotten: forgotten, succeeded: succeeded)
    }

    /// The same sheet with **sentences of its own** — for the profile PIN (AP52), whose wording
    /// must not be "applies only on this device": it travels via iCloud.
    init(
        job: PinTask, header: PinHeader, verifies: @escaping (String) -> Bool,
        sets: @escaping (String) -> Bool, forgotten: (() -> Void)?,
        succeeded: @escaping () -> Void
    ) {
        self.job = job
        self.headerSentences = header
        self.verifies = verifies
        self.sets = sets
        self.forgotten = forgotten
        self.succeeded = succeeded
        _input = State(initialValue: PinEntry(start: job.verifies ? .verify : .fresh))
    }

    private var tier: PinEntry.Tier { input.tier }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: MetricsBoard.phone.gutter)
            NumberPad(
                digits: $digits, locations: Pin.locations, wrong: wrong,
                forgotten: tier == .verify ? forgotten : nil, full: verify)
            Spacer(minLength: MetricsBoard.phone.gutter)
        }
        .padding(.top, MetricsBoard.phone.gutter)
        .padding(.bottom, MetricsBoard.phone.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorRole.surfaceHigh.color)
        // **Only the failed attempt reports, success does not.** Whoever typed correctly
        // sees the door open; whoever mistyped sees four dots change color
        // — in the dark, with the thumb over the keyboard, at the point where
        // you do not look at the screen anyway. The same split as with the
        // system password.
        //
        // **And the sentence stands beside it** (``sentenceRow``): a shake without a message would be
        // an error you cannot read up on — the condition from ``Haptics``.
        //
        // ``wrong`` falls back by itself after four hundred milliseconds; without
        // the condition every typo would get a second jolt on clearing.
        .haptics(.rejected, at: wrong, when: { _, jetztFalsch in jetztFalsch })
    }

    // MARK: - The head

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: Glyph.locked.name)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .frame(width: 44, height: 44)
                .background(ColorRole.surface.color, in: Circle())
                .padding(.bottom, 6)

            Text(appKey: headline)
                .font(TypeLevel.title.font)
                .foregroundStyle(ColorRole.text.color)
                .multilineTextAlignment(.center)

            // **The door's sentence is shown literally**, not translated: it comes from
            // ``LockedDoors`` and belongs to the rule, not to the interface.
            sentenceRow
                .font(TypeLevel.footer.font)
                .foregroundStyle(report == nil ? ColorRole.textMatt.color : ColorRole.brandLight.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, MetricsBoard.phone.margin + 4)
        .accessibilityElement(children: .combine)
    }

    /// Which heading belongs to which stage.
    private var row: PinHeader.Row {
        switch tier {
        case .verify: headerSentences.verify
        case .fresh: headerSentences.fresh
        case .repeatEntry: headerSentences.repeatEntry
        }
    }

    private var headline: String { row.title }

    @ViewBuilder
    private var sentenceRow: some View {
        if let report {
            Text(appKey: report)
        } else {
            switch row.message {
            case .key(let name): Text(appKey: name)
            case .wording(let text): Text(verbatim: text)
            }
        }
    }

    // MARK: - The check

    /// **The last digit decides.** A "Continue" button below it would be a press that
    /// adds nothing — the entry is finished with the fourth digit.
    private func verify(_ full: String) {
        digits = ""
        switch input.take(full, verify: verifies) {
        case .verified:
            report = nil
            if job == .changePin {
                input.continueToNew()
            } else {
                succeeded()
            }
        case .wrong:
            reject("pin.wrong")
        case .repeatEntry:
            report = nil
        case .deviation:
            reject("pin.mismatch")
        case .chosen(let pin):
            guard sets(pin) else {
                input = PinEntry(start: .fresh)
                return reject("childLock.pin.invalid")
            }
            succeeded()
        }
    }

    /// **Clear, report, stay.** A sheet that closes on a typo
    /// forces a second trip there — and whoever mistypes once usually mistypes
    /// twice.
    private func reject(_ message: String) {
        withAnimation(Motion.stateChange) {
            wrong = true
            report = message
        }
        digits = ""
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            withAnimation(Motion.stateChange) { wrong = false }
        }
    }
}

/// What the ``PinSheet`` says above the keypad per stage — **heading and sentence.**
///
/// **The finding that made this necessary** (AP52): the sheet knew only the device PIN, and
/// its sentences are wrong for a profile PIN. "Four digits. They apply only on this
/// device" above a PIN that travels via iCloud to every device would be wrong
/// information in front of a lock — and that is worse than none at all.
struct PinHeader: Equatable {

    /// One stage: heading as a key, sentence as a key or wording.
    struct Row: Equatable {
        let title: String
        let message: PinTask.Wording
    }

    let verify: Row
    let fresh: Row
    let repeatEntry: Row

    /// The repetition is the same for every PIN.
    static let replay = Row(
        title: "pin.repeat", message: .key("childLock.ask.repeat.text"))

    /// The sentences of the **device PIN** — as up to AP52.
    static func forItem(_ job: PinTask) -> PinHeader {
        PinHeader(
            verify: Row(title: job.headline, message: job.message),
            fresh: Row(title: "pin.enterNew", message: .key("childLock.ask.create.text")),
            repeatEntry: replay)
    }

    /// What a profile's PIN is being asked for.
    enum ProfileQuestion: Equatable {
        /// The latch before switching to this profile.
        case lock
        /// Set the first PIN.
        case set
        /// First the old one, then a new one.
        case change
        /// The old one, after that it is gone.
        case remove
    }

    /// The sentences of the **profile PIN** — with the name, so that nobody guesses whose PIN is
    /// being asked.
    static func profile(_ query: ProfileQuestion, name: String) -> PinHeader {
        let reason = PinTask.Wording.wording(SettingsModel.text("profiles.pinReason %@", name))
        let hint = PinTask.Wording.wording(SettingsModel.text("profiles.pinHint %@", name))
        let fresh = Row(title: "pin.create", message: .key("profiles.pinSetText"))
        switch query {
        // **Nothing is checked on setting** — the "check" row there is the same as at the
        // latch and stays unused, because ``PinTask/assignPin`` starts anew right away.
        case .lock, .set:
            return PinHeader(
                verify: Row(title: "pin.enter", message: reason), fresh: fresh,
                repeatEntry: replay)
        case .change:
            return PinHeader(
                verify: Row(title: "pin.enterOld", message: hint), fresh: fresh,
                repeatEntry: replay)
        case .remove:
            return PinHeader(
                verify: Row(title: "profiles.pinRemove", message: hint), fresh: fresh,
                repeatEntry: replay)
        }
    }
}
