// Sparkle is macOS-only: on iOS updates come through the App Store, and the
// framework is not linked there — hence the whole-file guard.
#if os(macOS)
import Observation
import Sparkle
import SwiftUI

/// Sparkle, wrapped for SwiftUI.
///
/// Updates come from GitHub Releases, with no server beyond that: `SUFeedURL`
/// in the Info.plist points at the `appcast.xml` asset of the latest release,
/// and Sparkle refuses any archive not signed by the EdDSA key whose public
/// half is `SUPublicEDKey`. See docs/RELEASING.md for how a release is cut.
@MainActor
@Observable
final class SparkleUpdaterModel {
    /// Mirrors `SPUUpdater.canCheckForUpdates`, which goes false while a
    /// check is already running, so the menu item disables itself.
    private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        // Starting the updater at launch is what enables scheduled checks;
        // Sparkle still asks the user's permission for those on second launch
        // rather than phoning home uninvited.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // KVO rather than Combine, per the house rule; the value hops to the
        // main actor because the updater may publish from anywhere.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

/// The "check for updates" menu item, in the app menu next to About, where
/// every Mac user's hand already knows to find it.
struct UpdateCommands: Commands {
    let updater: SparkleUpdaterModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button {
                updater.checkForUpdates()
            } label: {
                Text("Zoek naar updates…", comment: "Menu item that checks for app updates")
            }
            .disabled(!updater.canCheckForUpdates)
        }
    }
}
#endif
