import Foundation
import Observation

/// The security choices, and where they are kept.
///
/// `UserDefaults` rather than the synced store, deliberately. "Is this device
/// locked after five minutes" and "does this device sync secrets" are
/// decisions about *this* device; syncing them would let a phone's settings
/// silently change a Mac's, which is the wrong direction for anything in this
/// file.
@MainActor
@Observable
final class SecuritySettings {
    enum LockDelay: String, CaseIterable, Identifiable, Sendable {
        case immediately
        case afterOneMinute
        case afterFiveMinutes
        case afterFifteenMinutes
        case never

        var id: String { rawValue }

        var interval: TimeInterval? {
            switch self {
            case .immediately: return 0
            case .afterOneMinute: return 60
            case .afterFiveMinutes: return 5 * 60
            case .afterFifteenMinutes: return 15 * 60
            case .never: return nil
            }
        }
    }

    private enum Key {
        static let lockEnabled = "security.lock.enabled"
        static let lockDelay = "security.lock.delay"
        static let syncsConfiguration = "security.sync.configuration"
        static let syncsSecrets = "security.sync.secrets"
    }

    private let defaults: UserDefaults

    var isLockEnabled: Bool {
        didSet { defaults.set(isLockEnabled, forKey: Key.lockEnabled) }
    }

    var lockDelay: LockDelay {
        didSet { defaults.set(lockDelay.rawValue, forKey: Key.lockDelay) }
    }

    /// CloudKit sync for hosts, groups, snippets, tunnels, fingerprints and
    /// settings. On by default, because that is what the brief calls for and
    /// none of it is a secret.
    ///
    /// Read once, when the model container is built. SwiftData decides at
    /// construction whether a store is CloudKit-backed, so changing this takes
    /// effect at the next launch — and the settings screen says so rather than
    /// pretending the switch did something.
    var syncsConfiguration: Bool {
        didSet { defaults.set(syncsConfiguration, forKey: Key.syncsConfiguration) }
    }

    /// Off by default, and the only setting in the app whose default is
    /// "no" on principle rather than on taste. Turning it on moves private
    /// keys and passwords into iCloud Keychain.
    var syncsSecrets: Bool {
        didSet { defaults.set(syncsSecrets, forKey: Key.syncsSecrets) }
    }

    var secretScope: SecretStorageScope {
        syncsSecrets ? .iCloudKeychain : .thisDeviceOnly
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isLockEnabled = defaults.bool(forKey: Key.lockEnabled)
        self.lockDelay = LockDelay(rawValue: defaults.string(forKey: Key.lockDelay) ?? "")
            ?? .afterFiveMinutes
        // `object(forKey:)` rather than `bool(forKey:)`: an absent key reads as
        // false, and configuration sync is meant to be on until someone turns
        // it off.
        self.syncsConfiguration = defaults.object(forKey: Key.syncsConfiguration) as? Bool ?? true
        self.syncsSecrets = defaults.bool(forKey: Key.syncsSecrets)
    }

    /// Read without building the whole object, for the model container, which
    /// is constructed before anything else exists.
    nonisolated static func syncsConfiguration(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.syncsConfiguration) as? Bool ?? true
    }

    nonisolated static func syncsSecrets(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.syncsSecrets)
    }
}
