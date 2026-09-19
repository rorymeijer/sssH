import Foundation
import LocalAuthentication
import Observation
import SwiftUI

/// Face ID, Touch ID or the device passcode in front of the app.
///
/// What it protects is not the stored secrets — those are protected by the
/// Keychain and the device key whatever this says — but the *session*: an
/// unlocked laptop on a desk, with a terminal already connected to production.
/// That is the threat this is for, and it is the common one.
///
/// Locking hides what is on screen as well as blocking input. A blur over a
/// terminal that still shows the last command is not a lock.
@MainActor
@Observable
final class AppLock {
    enum Availability: Sendable, Equatable {
        case biometric(String)
        case passcodeOnly
        /// No passcode set at all. The lock cannot be offered, and saying so
        /// is better than a switch that silently does nothing.
        case unavailable
    }

    private(set) var isLocked = false
    private(set) var availability: Availability = .unavailable
    /// Set when an unlock attempt failed for a reason worth showing. Cleared on
    /// the next attempt.
    private(set) var lastFailure: String?

    private let settings: SecuritySettings
    /// When the app last went to the background. `nil` while it is in front.
    private var backgroundedAt: Date?
    /// Whether an authentication prompt is already up. The lock screen can be
    /// on screen more than once — the main window's overlay and the settings
    /// window both show it — and each asks on appear; one prompt is plenty.
    private var isAuthenticating = false

    init(settings: SecuritySettings) {
        self.settings = settings
        refreshAvailability()
    }

    // MARK: - Availability

    func refreshAvailability() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            availability = .unavailable
            return
        }
        switch context.biometryType {
        case .faceID:
            availability = .biometric("Face ID")
        case .touchID:
            availability = .biometric("Touch ID")
        case .opticID:
            availability = .biometric("Optic ID")
        default:
            availability = .passcodeOnly
        }
    }

    var canLock: Bool { availability != .unavailable }

    // MARK: - Lifecycle

    /// Locks immediately, whatever the delay says. For the menu item and for a
    /// user who wants it locked now.
    func lockNow() {
        guard settings.isLockEnabled, canLock else { return }
        isLocked = true
        backgroundedAt = nil
    }

    func applicationDidEnterBackground(at date: Date = Date()) {
        guard settings.isLockEnabled, canLock else { return }
        if settings.lockDelay == .immediately {
            isLocked = true
            backgroundedAt = nil
        } else {
            backgroundedAt = date
        }
    }

    func applicationWillEnterForeground(at date: Date = Date()) {
        guard settings.isLockEnabled, canLock else {
            isLocked = false
            return
        }
        guard let backgroundedAt, let interval = settings.lockDelay.interval else {
            // `.never`, or the app was never actually backgrounded.
            self.backgroundedAt = nil
            return
        }
        if date.timeIntervalSince(backgroundedAt) >= interval {
            isLocked = true
        }
        self.backgroundedAt = nil
    }

    /// Called when the setting is switched on, so the lock takes effect the
    /// next time the app leaves the foreground rather than at once — turning a
    /// switch on should not throw the user out of what they are doing.
    func settingsChanged() {
        refreshAvailability()
        if !settings.isLockEnabled { isLocked = false }
    }

    // MARK: - Unlocking

    func unlock() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        lastFailure = nil
        let context = LAContext()
        // The system's own wording for the fallback, so it says "Enter
        // Passcode" or "Enter Password" as the platform expects.
        context.localizedFallbackTitle = ""

        let reason = String(
            localized: "Ontgrendel sssH om verder te gaan met je sessies.",
            comment: "Reason shown by the system when asking for Face ID, Touch ID or the passcode"
        )

        do {
            // `.deviceOwnerAuthentication`, not `.deviceOwnerAuthenticationWithBiometrics`:
            // the passcode fallback matters. A user whose Face ID fails in the
            // dark must not be locked out of their own terminal.
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if success { isLocked = false }
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                // Not a failure worth a message; the user chose to stay locked.
                break
            default:
                lastFailure = error.localizedDescription
            }
        } catch {
            lastFailure = error.localizedDescription
        }
    }
}
