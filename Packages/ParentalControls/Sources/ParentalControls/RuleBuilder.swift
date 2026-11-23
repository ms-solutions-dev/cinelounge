import Core
import Foundation

/// **How the stored values become a ``ProtectionRule`` — once for both programs**
/// (AP58 R1, finding K2).
///
/// Until here TV and phone each computed the rule together in their own
/// `ParentalControlsState`, with the same sentences in the comments and two differences in the
/// code: the TV read the channel allow list for **every** profile, the phone only for children;
/// the TV read limit and lock via ``AgeLimit/applicable(from:forItem:)``, the phone via
/// ``AgeLimit/forItem(profile:device:)``. **Now the calculation stands here**, and both states
/// are observers that store, read and notice — but do not compute.
///
/// **Two parts, because they live for different lengths of time.** The device baseline changes
/// only when someone turns the parental controls; the person's part at every profile switch.
/// The phone remembers both separately (``rule`` is asked there per title), the TV reads them
/// together anew.
public enum RuleBuilder {

    /// What the **device** contributes — the baseline that applies to everyone sitting in front of
    /// it.
    public struct Device: Sendable, Equatable {
        public var locked: Bool
        public var isPinSet: Bool
        public var limit: AgeLimit?
        /// Including the default "yes" (``UnrecognizedLock/read(from:forItem:)``).
        public var blocksUnrecognized: Bool
        public var assignments: [String: Int]

        public init(
            locked: Bool, isPinSet: Bool, limit: AgeLimit? = nil,
            blocksUnrecognized: Bool = true, assignments: [String: Int] = [:]
        ) {
            self.locked = locked
            self.isPinSet = isPinSet
            self.limit = limit
            self.blocksUnrecognized = blocksUnrecognized
            self.assignments = assignments
        }

        /// The baseline from the store — the Keychain, where the PIN also lies.
        public static func read(locked: Bool, from store: any KeyValueStore) -> Device {
            Device(
                locked: locked, isPinSet: Pin(store: store).isSet,
                limit: AgeLimit.read(from: store),
                blocksUnrecognized: UnrecognizedLock.read(from: store),
                assignments: UnrecognizedRatings.load(from: store).assignments)
        }
    }

    /// What the **person** contributes — without the device baseline.
    public struct Person: Sendable, Equatable {
        public var identifier: String?
        public var isChild: Bool
        public var limit: AgeLimit?
        /// What stands **on the profile**, `nil` if nothing — an unset profile stays silent
        /// (strand G, 2026-09-25), then the device decides.
        public var blocksUnrecognized: Bool?
        public var assignments: [String: Int]
        /// Which channel groups this child may see — **empty for every profile that is not a child**,
        /// and empty means no Live.
        public var channelApproval: ChannelApproval

        public init(
            identifier: String?, isChild: Bool, limit: AgeLimit? = nil,
            blocksUnrecognized: Bool? = nil, assignments: [String: Int] = [:],
            channelApproval: ChannelApproval = ChannelApproval()
        ) {
            self.identifier = identifier
            self.isChild = isChild
            self.limit = limit
            self.blocksUnrecognized = blocksUnrecognized
            self.assignments = assignments
            self.channelApproval = channelApproval
        }

        /// Nobody is sitting in front of it — the state before the first setup. Then the device baseline
        /// applies alone.
        public static let nobody = Person(identifier: nil, isChild: false)

        /// This person's part from the store.
        ///
        /// **The allow list for channels only for a child** (AP58 R1, fail-closed decision). The TV read
        /// it for every profile until here: an adult under device lock with a stored list got Live
        /// there, on the phone not. Nobody chose a list on an adult profile for a child — so it does
        /// not apply.
        public static func read(
            _ identifier: String?, isChild: Bool, from store: any KeyValueStore
        ) -> Person {
            guard let identifier else { return .nobody }
            return Person(
                identifier: identifier, isChild: isChild,
                limit: AgeLimit.read(from: store, forItem: identifier),
                blocksUnrecognized: UnrecognizedLock.own(from: store, forItem: identifier),
                assignments: UnrecognizedRatings.load(from: store, forItem: identifier).assignments,
                channelApproval: isChild
                    ? ChannelApproval.load(from: store, forItem: identifier) : ChannelApproval())
        }
    }

    /// The rule from device, person and the marker of the old accounts list.
    ///
    /// * **Account type:** child profile **or** child account (G1) — with OR, because the old list
    ///   carries the households from before AP41, and dropping them would open a lock somebody set
    ///   deliberately. Without a signed-in account the profile applies.
    /// * **Limit:** the stricter of profile and device (``AgeLimit/forItem(profile:device:)``).
    /// * **Lock the not understood:** either of the two locks, a profile without an entry stays
    ///   silent (``UnrecognizedLock/forItem(profile:device:)``).
    /// * **Mappings:** both boards, the profile has the last word.
    /// * **Channel allow list:** the person's, there is no device baseline for it.
    public static func rule(device: Device, person: Person, accountIsChild: Bool) -> ProtectionRule {
        ProtectionRule(
            deviceLocked: device.locked,
            accountKind: person.isChild || accountIsChild ? .kind : .adult,
            isPinSet: device.isPinSet,
            limit: AgeLimit.forItem(profile: person.limit, device: device.limit),
            blocksUnrecognized: UnrecognizedLock.forItem(
                profile: person.blocksUnrecognized, device: device.blocksUnrecognized),
            assignments: device.assignments.merging(
                person.assignments, uniquingKeysWith: { _, ausProfil in ausProfil })
        )
        .using(channelApproval: person.channelApproval)
    }

    /// The same rule, read from the store in one go.
    public static func rule(
        profile identifier: String?, profileIsChild: Bool, accountIsChild: Bool, deviceLocked: Bool,
        from store: any KeyValueStore
    ) -> ProtectionRule {
        rule(
            device: .read(locked: deviceLocked, from: store),
            person: .read(identifier, isChild: profileIsChild, from: store),
            accountIsChild: accountIsChild)
    }
}

/// **The doors and their pass — once for both programs** (AP58 R1, finding K2).
///
/// The TV checks and consumes at the action in one go (``passesThrough(_:rule:)``), the phone asks
/// for an order and consumes after the grab (``job(forItem:rule:)``, ``consume()``). Both
/// forms stand here, over **one** ``Pass``: a passed PIN is valid for one door and expires
/// after two minutes.
public struct DoorGuard: Sendable, Equatable {

    private var pass = Pass()

    public init() {}

    /// Whether the content behind this door should currently be covered — **without consuming
    /// anything**; may be asked as often as wanted, also on every redraw.
    public func isHidden(_ door: String, rule: ProtectionRule, um now: Date = Date()) -> Bool {
        rule.requiresPin(forItem: door) && !pass.applies(forItem: door, um: now)
    }

    /// Whether this door opens now — **and in doing so consumes a valid pass.**
    public mutating func passesThrough(_ door: String, rule: ProtectionRule, um now: Date = Date()) -> Bool {
        guard rule.requiresPin(forItem: door) else { return true }
        guard pass.applies(forItem: door, um: now) else { return false }
        pass.consume()
        return true
    }

    /// The order with which the PIN sheet opens — or `nil` if the way is clear.
    public func job(forItem door: String, rule: ProtectionRule, um now: Date = Date()) -> PinTask? {
        guard isHidden(door, rule: rule, um: now) else { return nil }
        return .door(identifier: door, reason: LockedDoors.reason(door) ?? "")
    }

    /// Opens a door if the digits are the PIN.
    @discardableResult
    public mutating func open(
        _ door: String, using digits: String, pin: Pin, um now: Date = Date()
    ) -> Bool {
        guard pin.matches(digits) else { return false }
        pass.open(door, um: now)
        return true
    }

    /// After the grab the door is closed again.
    public mutating func consume() { pass.consume() }
}
