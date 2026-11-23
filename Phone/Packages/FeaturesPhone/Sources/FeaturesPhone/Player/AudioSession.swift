import Core
import Diagnose
import Foundation

// **`canImport(UIKit)` and not `canImport(AVFAudio)`.** The module exists on the Mac
// too, `AVAudioSession` in it does not — the tests run there, and they check the
// interpretation of the messages and not the session itself.
#if canImport(UIKit)
    import AVFAudio
#endif

/// Category, interruptions, change of the audio route.
///
/// **It is not one item among the others but their prerequisite.** Without the
/// `.playback` category iOS treats playback as an accessory: the sound goes silent as
/// soon as the screen turns off, the switch on the side mutes it — and **the system does
/// not even offer Picture in Picture.** `UIBackgroundModes: audio` has been in
/// `project.yml` since day one; `AVAudioSession` occurred **not once** in the whole
/// project. The promise stood, the delivery was missing.
///
/// **Either completely or not at all.** From the market research: Swiftfin #1400 —
/// *"iOS thinks it is playing, the sound is not playing"*. The intermediate state is
/// worse than no feature, because it looks like a defect of the device.
///
/// **Two events that do not exist on the TV**, and both end a playback: a call
/// interrupts, and unplugged headphones change the audio route. Without a record you see
/// afterwards only "it stopped" — that is why each of the two writes into
/// ``PhoneEvent``.
///
/// **Resuming after an interruption is a request, not a rule.** iOS sends `shouldResume`
/// along with the end; anyone who plays on without this permission talks into the
/// viewer's phone call. And with unplugged headphones it **never** resumes: Apple's own
/// rule, and the only right one — the film would otherwise continue over the speaker, on
/// the train.
@MainActor
public final class AudioSession {

    /// What the session has to tell the player.
    public struct Commands: Sendable {
        /// Stop — an interruption has begun, or the headphones are gone.
        public var stop: @MainActor () -> Void
        /// Resume — and **only** if the system allows it.
        public var resume: @MainActor () -> Void

        public init(
            stop: @escaping @MainActor () -> Void,
            resume: @escaping @MainActor () -> Void
        ) {
            self.stop = stop
            self.resume = resume
        }
    }

    private var commands: Commands?
    private var observers: [NSObjectProtocol] = []

    public init() {}

    /// Open the session — **once per playback, before the first picture.**
    public func begin(_ commands: Commands) {
        // **Already open: only swap the commands** (2026-10-19). ``PlayerModel/start()``
        // runs again for live TV after every dried-up supply; until then the session was
        // re-activated every time and one more observer was attached per startup — an
        // interruption then stopped playback several times over, and the re-activation is the
        // suspect behind the volume bar that came up without a key press.
        guard self.commands == nil else {
            self.commands = commands
            return
        }
        self.commands = commands
        #if canImport(UIKit)
            let session = AVAudioSession.sharedInstance()
            do {
                // **`.playback` and `.moviePlayback`.** The category says "this is the purpose of the
                // app", the mode says "it is a film" — and on that hangs iOS treating volume control and
                // ducking correctly.
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
            } catch {
                // **A note and not an abort.** Without a session the picture runs anyway; what is
                // missing is the background sound. Anyone who aborted here would let a film fail on a
                // setting.
                Diagnose.hint(.playback, "Audio session not opened", error)
            }
            record(session)
            attach(session)
        #endif
    }

    /// Close the session — **and the observers with it.**
    ///
    /// Without unregistering, one observer would remain per playback, and the tenth film
    /// would stop ten times over when someone calls.
    public func finish() {
        for observers in observers { NotificationCenter.default.removeObserver(observers) }
        observers = []
        commands = nil
        #if canImport(UIKit)
            do {
                // **`.notifyOthersOnDeactivation`**: what was running before — music, an audiobook —
                // may continue by itself afterwards.
                try AVAudioSession.sharedInstance().setActive(
                    false, options: .notifyOthersOnDeactivation)
            } catch {
                Diagnose.hint(.playback, "Audio session not closed", error)
            }
        #endif
    }

    #if canImport(UIKit)
        /// Writes down what the sound of this device is really running with.
        ///
        /// **The reason these lines exist** (2026-09-07): the question was raised that the sound
        /// problem does not occur on the TV, and how it is solved there. Checked: it is **not**
        /// solved there — the engine, the sample queue and their caps are the same source code,
        /// and the TV's reports show the same growing lead (measured there up to 57.6 s). What
        /// does not exist on the TV is **this class**: `AVAudioSession` is a piece of iOS and has
        /// no counterpart on tvOS.
        ///
        /// **That makes it the first place where the two apps can differ** — and the only one in
        /// the audio chain about which no number had so far been in the report. The numbers that
        /// give away a resampling are therefore written: if the system runs at 44,100 Hz while the
        /// channel delivers 48,000, iOS converts every packet, and that is exactly what one hears
        /// as "not quite clean".
        ///
        /// **Measured and not set.** Setting a preferred sample rate would be a repair without a
        /// finding; first it has to be written down what the device does.
        private func record(_ session: AVAudioSession) {
            let route = session.currentRoute.outputs.map { "\($0.portType.rawValue)" }
                .joined(separator: ", ")
            // **Into the playback trace and not into the UI ledger.** The line belongs next to
            // "Audio: MPEG Audio Layer 2 …" and "Renderer: clock starts" — it is read there, and it
            // stands there in the same order as what it refers to.
            Diagnostics.playbackStep(
                "Audio session: \(Int(session.sampleRate)) Hz "
                    + "(preferred \(Int(session.preferredSampleRate)) Hz), "
                    + "buffer \(Int(session.ioBufferDuration * 1000)) ms, "
                    + "\(session.outputNumberOfChannels) channels, route: "
                    + (route.isEmpty ? "none" : route), since: nil)
        }

        /// **The numbers are read in the callback, the notification is not passed on.**
        ///
        /// `Notification` is not `Sendable`; carrying it into a main-queue environment is an
        /// error under strict concurrency — and a justified one: the translator does not know
        /// what happens to it afterwards. Two `UInt` it does know.
        private func attach(_ session: AVAudioSession) {
            let midpoint = NotificationCenter.default
            observers.append(
                midpoint.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: session,
                    queue: .main
                ) { [weak self] report in
                    let kind = report.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    let hints =
                        report.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                    MainActor.assumeIsolated { self?.interruption(kind, hints) }
                })
            observers.append(
                midpoint.addObserver(
                    forName: AVAudioSession.routeChangeNotification, object: session,
                    queue: .main
                ) { [weak self] report in
                    let reason = report.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    MainActor.assumeIsolated { self?.audioPath(reason) }
                })
        }

        private func interruption(_ raw: UInt?, _ hints: UInt?) {
            guard let raw, let kind = AVAudioSession.InterruptionType(rawValue: raw) else {
                return
            }

            switch kind {
            case .began:
                PhoneEvent.interrupted.note("begins")
                commands?.stop()
            case .ended:
                // **`shouldResume` is the system's permission.** Playing on without it would mean
                // talking into a conversation that is still going on.
                let isAllowed =
                    hints.map {
                        AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume)
                    } ?? false
                PhoneEvent.interrupted.note(isAllowed ? "ended, playback continues" : "ended")
                if isAllowed { commands?.resume() }
            @unknown default:
                break
            }
        }

        private func audioPath(_ raw: UInt?) {
            guard let raw, let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else {
                return
            }

            PhoneEvent.audioRouteChanged.note(Self.wording(reason))
            // **And into the trace, with the numbers after it.** A switch away in the middle of the
            // film can change the sample rate of the system; without the numbers next to it the
            // change is a fact without consequence.
            record(AVAudioSession.sharedInstance())
            // **Only for the old device that is gone — and then always stop.** Apple's own rule:
            // anyone who unplugs the headphones does not want the film to continue over the speaker.
            // A change in the other direction (headphones **on**) stops nothing.
            if reason == .oldDeviceUnavailable { commands?.stop() }
        }

        static func wording(_ reason: AVAudioSession.RouteChangeReason) -> String {
            switch reason {
            case .newDeviceAvailable: "new device connected"
            case .oldDeviceUnavailable: "device disconnected"
            case .categoryChange: "category changed"
            case .override: "overridden by the app"
            case .wakeFromSleep: "woke from sleep"
            case .noSuitableRouteForCategory: "no suitable route"
            case .routeConfigurationChange: "route configuration changed"
            case .unknown: "reason unknown"
            @unknown default: "reason unknown"
            }
        }
    #endif
}
