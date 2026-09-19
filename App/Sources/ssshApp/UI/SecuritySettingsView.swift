import SwiftUI

/// The security and sync settings, and what each one actually means.
///
/// Every switch here says what it does to the data, because the difference
/// between "syncs" and "syncs end-to-end encrypted" is the whole question and
/// nobody can be expected to infer it from a label.
struct SecuritySettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var showsSecretSyncConfirmation = false

    var body: some View {
        // These settings are what turns the lock off, so they sit behind it
        // too: a lock whose own switch is reachable while locked is not a
        // lock. Gated here, in the view itself, so every way in — the macOS
        // Settings window, the sheet on iOS — is covered.
        if environment.appLock.isLocked {
            LockScreenView(lock: environment.appLock)
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 520)
                #endif
        } else {
            settingsForm
        }
    }

    @ViewBuilder
    private var settingsForm: some View {
        @Bindable var security = environment.security

        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(
                        get: { security.isLockEnabled },
                        set: { isOn in
                            security.isLockEnabled = isOn
                            environment.appLock.settingsChanged()
                        }
                    )) {
                        Text("Appvergrendeling", comment: "Toggle that turns the app lock on")
                    }
                    .disabled(!environment.appLock.canLock)

                    if security.isLockEnabled {
                        Picker(selection: $security.lockDelay) {
                            Text("Meteen", comment: "Lock delay: immediately").tag(SecuritySettings.LockDelay.immediately)
                            Text("Na 1 minuut", comment: "Lock delay: one minute").tag(SecuritySettings.LockDelay.afterOneMinute)
                            Text("Na 5 minuten", comment: "Lock delay: five minutes").tag(SecuritySettings.LockDelay.afterFiveMinutes)
                            Text("Na 15 minuten", comment: "Lock delay: fifteen minutes").tag(SecuritySettings.LockDelay.afterFifteenMinutes)
                            Text("Nooit", comment: "Lock delay: never").tag(SecuritySettings.LockDelay.never)
                        } label: {
                            Text("Vergrendelen", comment: "Label for the lock delay picker")
                        }
                    }
                } header: {
                    Text("Vergrendeling", comment: "Section header for the app lock")
                } footer: {
                    switch environment.appLock.availability {
                    case .unavailable:
                        Text("Dit apparaat heeft geen toegangscode. Zonder toegangscode kan sssH niets vergrendelen.",
                             comment: "Explains that the lock needs a device passcode")
                    case .passcodeOnly:
                        Text("Vergrendelt de app, niet de verbindingen: sessies blijven open en komen terug zodra je ontgrendelt.",
                             comment: "Explains what the app lock does and does not do")
                    case .biometric(let name):
                        Text("Ontgrendelen kan met \(name) of met je toegangscode. Sessies blijven open en komen terug zodra je ontgrendelt.",
                             comment: "Explains the app lock, naming the biometric method")
                    }
                }

                Section {
                    Toggle(isOn: $security.syncsConfiguration) {
                        Text("Hosts en instellingen synchroniseren", comment: "Toggle for CloudKit sync of configuration")
                    }
                } header: {
                    Text("Synchronisatie", comment: "Section header for sync settings")
                } footer: {
                    Text("Hosts, groepen, fragmenten, tunnels en hostsleutel-vingerafdrukken gaan via je eigen iCloud. Wachtwoorden en sleutels niet — die staan in de sleutelhanger. Een wijziging werkt bij de volgende start.",
                         comment: "Explains exactly what configuration sync covers and that it needs a restart")
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { security.syncsSecrets },
                        set: { isOn in
                            if isOn {
                                // Asked before, not after. Turning this on
                                // moves private keys onto other machines, and
                                // that is not something to discover from a
                                // switch that was already flipped.
                                showsSecretSyncConfirmation = true
                            } else {
                                security.syncsSecrets = false
                                Task { await environment.applySecretScope() }
                            }
                        }
                    )) {
                        Text("Ook wachtwoorden en sleutels", comment: "Toggle for opt-in secret sync")
                    }
                } footer: {
                    Text("Uit: sleutels en wachtwoorden blijven op dit apparaat, versleuteld met een sleutel die het apparaat niet kan verlaten. Aan: ze gaan via iCloud-sleutelhanger, die end-to-end versleuteld is — maar dan kan dit apparaat ze niet meer met zijn eigen sleutel beschermen. Ze gaan nooit via de gewone iCloud-database.",
                         comment: "Explains the trade-off between device-only secrets and iCloud Keychain sync")
                }

                Section {
                    LabeledContent {
                        protectionValue
                    } label: {
                        Text("Sleutelbescherming", comment: "Label for how the device key is protected")
                    }
                } footer: {
                    Text("Opgeslagen geheimen worden versleuteld met een sleutel van dit apparaat voordat ze in de sleutelhanger gaan.",
                         comment: "Explains that secrets are wrapped before storage")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text("Beveiliging", comment: "Title of the security settings"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Gereed", comment: "Button that closes the shell integration sheet")
                    }
                }
            }
            .confirmationDialog(
                Text("Sleutels en wachtwoorden synchroniseren?", comment: "Title of the secret sync confirmation"),
                isPresented: $showsSecretSyncConfirmation,
                titleVisibility: .visible
            ) {
                Button {
                    security.syncsSecrets = true
                    Task { await environment.applySecretScope() }
                } label: {
                    Text("Synchroniseren", comment: "Button that confirms turning on secret sync")
                }
                Button(role: .cancel) { } label: {
                    Text("Annuleer", comment: "Cancel button")
                }
            } message: {
                Text("Je privésleutels en wachtwoorden komen dan op je andere Apple-apparaten te staan, via de iCloud-sleutelhanger. Dat is end-to-end versleuteld, maar ze staan dan niet langer alleen hier.",
                     comment: "Explains what turning on secret sync does before it happens")
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }

    /// Reported rather than claimed. An Intel Mac without a T2 has no Secure
    /// Enclave, and saying "Secure Enclave" there would be a lie the user might
    /// rely on.
    @ViewBuilder
    private var protectionValue: some View {
        switch environment.keyProtection {
        case .secureEnclave:
            Label {
                Text("Secure Enclave", comment: "The device key is hardware-backed")
            } icon: {
                Image(systemName: "checkmark.shield.fill")
            }
            .foregroundStyle(.green)
        case .softwareKey:
            Label {
                Text("Sleutelhanger van dit apparaat", comment: "The device key is software-only")
            } icon: {
                Image(systemName: "shield")
            }
            .foregroundStyle(.secondary)
        case nil:
            Text("Onbekend", comment: "The device key's protection could not be determined")
                .foregroundStyle(.secondary)
        }
    }
}
