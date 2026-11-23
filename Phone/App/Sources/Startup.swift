import Core
import DesignSystemPhone
import Diagnose
import FeaturesPhone
import Foundation
import ParentalControls

/// What happens at startup — and what explicitly does not.
///
/// **Not:** sign in, reload, ask the server. Without a network the app is supposed to open
/// and the downloads to be there immediately; that is a check step of its own in `check.sh`
/// and therefore a place of its own in the code.
///
/// **But:** clean up what the last run left behind. Cleanup belongs here and not at the
/// place where something is created — there it would run for every stored image instead of
/// once.
enum Startup {

    /// Connects the image layer to the error log — **as the very first thing**, so that even
    /// the first image that does not load writes a line.
    ///
    /// Until 2026-09-26 ``DesignSystemPhone/ImageLoader`` called `Diagnose` itself; since then it
    /// reports to ``DesignSystemPhone/ImageMessage``, and only here does that become a line in
    /// the log (AP58, finding A16).
    static func forwardImageNotifications() {
        ImageMessage.derive { report in
            let area: Area =
                switch report.area {
                case .network: .network
                case .downloads: .downloads
                }
            switch report.kind {
            case .step: Diagnose.step(area, report.message)
            case .hint: Diagnose.hint(area, report.message)
            case .error: Diagnose.error(area, report.message)
            }
        }
    }

    /// Sets the chosen color scheme — **before the first screen and not next to it.**
    ///
    /// **The checkmark lied.** Area 6 sets ``Styling/ColorBoard/current`` on tap and stores
    /// the ID under ``ColorBoard/storeKey``; at startup nobody read it. On the next
    /// startup the board was back on ``ColorBoard/cinema`` while the checkmark in Settings still
    /// pointed to "Contrast" — and a checkmark that claims something other than the screen next
    /// to it is worse than none.
    ///
    /// **No Observable rebuild of the palette.** ``Styling/ColorBoard/current`` is a table and
    /// not state; observing it would mean hooking every view build of the whole app to it so
    /// that a color changes three times in a lifetime.
    ///
    /// **First bring over the choice from before R7**
    /// (``Core/ColorPattern/adoptLegacyCatalog(device:keychain:in:)``): until then it lay
    /// here in `UserDefaults`, before that under `app.theme` with German IDs. Without this step
    /// every set-up phone would be back on "Cinema" after the update.
    @MainActor
    static func applyColorScheme(
        from store: UserDefaults = .standard, keychain: SecureStore = SecureStore()
    ) {
        ColorPattern.adoptLegacyCatalog(device: store, keychain: keychain)
        guard let board = ColorBoard.zu(id: ColorPattern.chosen(), forItem: .phone) else { return }
        ColorBoard.current = board
    }

    /// Brings the child-account tokens into the shared store — **once** (AP40).
    ///
    /// They lay here in `UserDefaults` (`accounts.children`) and on the TV in the Keychain
    /// (`accounts.children`) — two versions of the same type, and therefore a token set over there
    /// never arrived here. Now it is **one** list in the ``Core/FileStore``; this call takes
    /// along what is already on this device and does nothing once that has happened.
    ///
    /// **The Keychain is read too**, although nothing was ever written to it here: on a device
    /// on which both programs ran, something can lie there — and silently lifting parental
    /// controls is the more expensive mistake.
    @MainActor
    static func migrateChildAccounts(from store: UserDefaults = .standard) {
        ChildAccountList().adoptOldLists(keychain: SecureStore(), store: store)
    }

    /// Brings the device ID under its new names — **before any other step.**
    ///
    /// It was called `app.deviceID` here and `device.id` on the TV. Whoever simply switches
    /// over finds nothing and rolls a fresh one — and **the media server sees a new device**:
    /// the old sign-in stays there as a device that never exists again.
    ///
    /// **That is why this call is at the very top.** ``Grundstock/DeviceIdentity/id(in:)``
    /// creates one on the first request; whoever asks before has missed the takeover, and it
    /// never takes effect again.
    @MainActor
    static func migrateDeviceIdentifier(from store: UserDefaults = .standard) {
        DeviceIdentity.adopt(from: "app.deviceID", in: store)
    }

    /// Brings the age limit and "Block what is not understood" from the old store — **once**
    /// (AP40, 2026-09-20).
    ///
    /// Both were here in `UserDefaults`, on the TV in the Keychain, under the **same** name.
    /// That is why the fix the TV got on 2026-09-11 for the age limit never arrived here — and why
    /// this is no cosmetic flaw: a set PIN without a limit looks like effective parental
    /// controls and lets everything through.
    @MainActor
    static func migrateParentalControls() {
        ParentalControlsState().adoptFromStore()
    }

    /// Brings the bridge address to where the TV stores it — **once** (AP40, 2026-09-20).
    ///
    /// The same name stood here and there but meant two stores: `UserDefaults` versus
    /// Keychain. ``SecondScreen/Takeover`` writes a handed-over bridge into the Keychain — so
    /// it never arrived here, just like the age limit before the same correction.
    @MainActor
    static func migrateBridgeAddress() {
        SetupState().adoptBridgeAddress()
    }

    /// Brings the shelf order from the Keychain into the file — **once.**
    ///
    /// It lay here as five strings under `home.…`, with a line break between the entries and a
    /// tab between ID and name; the TV stored the same thing under `shelves.…`, with `;` and
    /// U+001F. By the rule from `ARCHITEKTUR.md` (section 8) that is structure and belongs in
    /// a file — now as ``Core/ShelfOrder`` in `shelves.json`, the same on both sides.
    @MainActor
    static func migrateShelfOrder() {
        StartPreferences.adopt(from: SecureStore(), in: FileStore())
    }

    /// Brings four small settings from the standard defaults into the file.
    ///
    /// **All four are structure** and lay in the wrong place (AP40, 2026-09-21): the deselected
    /// tabs, the remembered sort order per catalog, the sports memo and the image position per
    /// aspect ratio. **The memo has been brought over since 2026-09-26 by
    /// ``Core/SportReminderListStore`` itself** (B5) — on first read, together with the TV's, and
    /// per profile. For the sort order a separator drops out: there, `fresh:from` stood in one
    /// word, "because `UserDefaults` does not handle nested dictionaries well".
    ///
    /// **What is not here belongs elsewhere.** The most recently open catalog, the most
    /// recently open section, the channel history and the path in the portal are **state** and
    /// belong in the state ledger (AP42); the fetched third-party ratings are a **cache**.
    /// Pulling them into the file now would mean moving them twice.
    @MainActor
    static func migrateStructure(from old: UserDefaults = .standard) {
        let file = FileStore()
        TabSelection.adopt(from: old, in: file)
        SortMemory.adopt(from: old, in: file)
        PictureFill.adopt(from: old, in: file)
    }

    /// Sets the recording to the remembered state — **before the first measurement.**
    ///
    /// **The bug that existed over there stands there as a warning** (`DebugMode.activate`):
    /// the only writer was the key press in Settings. After every restart the value was back
    /// on Off, whatever the store said — the switch showed On, and the app recorded sparsely.
    ///
    /// **On the phone nobody called it at all until 2026-09-06** `DebugMode.current` thereby stayed
    /// off forever, `TraceRecorder.shared` never got a line, and the "Recording" section in the
    /// report was empty — in every report there ever was. Measuring happened anyway: the error
    /// trace runs independently of it. But exactly the history in which one sees a **stutter**
    /// (as opposed to a failure) was missing.
    @MainActor
    static func restoreRecording(from keychain: SecureStore = SecureStore()) {
        DebugMode.activate(from: keychain)
        let on = DebugMode.current.isOn
        Task { await ErrorLog.shared.setVerbose(on) }
    }

    /// Runs next to the first screen, not before it.
    ///
    /// Counting through the image store costs noticeable time with a few thousand files. Run
    /// before the first screen, it would be a delay at startup — and one that grows with every
    /// week of use.
    static func cleanUp() {
        Task.detached(priority: .utility) {
            await ImageStore.shared.cleanUpOnce()
            // **And the error log that nobody cleaned up until 2026-09-07** (AP10).
            // ``Diagnose/Cleanup`` has always had two rules — at most 2000 entries, at most
            // fourteen days —, and ``Diagnose/ErrorLog/cleanUp(now:)`` implements them. In the
            // whole project **only one check** called it.
            //
            // **The version change is no answer to that.** It starts the log over with every *build*;
            // between two builds it keeps growing without limit, and for the viewer there are weeks
            // between two builds. It is a file that is only appended to.
            //
            // **Here and not when writing.** Rewriting the log costs more than appending — run on every
            // entry it would be exactly the mistake that the explanation above describes for the image
            // store.
            let route = await ErrorLog.shared.cleanUp()
            if route > 0 { Diagnose.step(.downloads, "Error log cleaned up: \(route) lines") }
        }
    }
}
