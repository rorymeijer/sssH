import SwiftUI

/// What is shown instead of the app while it is locked.
///
/// Opaque, not blurred. A blur over a terminal still shows the shape of the
/// last command and the colour of an error, and an over-the-shoulder reader
/// does not need much. The whole point is that nothing is legible.
struct LockScreenView: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    // `.largeTitle` rather than a fixed size: a person who has
                    // set a larger text size has done so for everything.
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text("sssH is vergrendeld", comment: "Title on the lock screen")
                    .font(.title2.weight(.medium))

                Text("Je sessies blijven open. Ontgrendel om ze weer te zien.",
                     comment: "Body on the lock screen, saying sessions are not closed")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let failure = lock.lastFailure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label { unlockLabel } icon: { Image(systemName: unlockSymbol) }
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(40)
            .frame(maxWidth: 420)
        }
        // Everything underneath is hidden from VoiceOver too. A lock that only
        // covers the pixels is not a lock.
        .accessibilityAddTraits(.isModal)
        .task {
            // Ask straight away. Most people want to unlock, not to look at a
            // screen with a button on it.
            await lock.unlock()
        }
    }

    private var unlockLabel: Text {
        switch lock.availability {
        case .biometric(let name):
            return Text("Ontgrendel met \(name)", comment: "Unlock button, naming the biometric method")
        case .passcodeOnly, .unavailable:
            return Text("Ontgrendelen", comment: "Unlock button with no biometric method")
        }
    }

    private var unlockSymbol: String {
        switch lock.availability {
        case .biometric(let name):
            return name == "Touch ID" ? "touchid" : "faceid"
        case .passcodeOnly, .unavailable:
            return "lock.open"
        }
    }
}
