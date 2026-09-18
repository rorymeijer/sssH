import SwiftUI

/// The About box, replacing the system one.
///
/// The stock panel shows a name, a version and a copyright line pulled from
/// the bundle. This one exists to also say who made the app and where the
/// source lives — for an open-source app that is the whole point of the box.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 8) {
            appIcon
                .frame(width: 96, height: 96)

            Text(verbatim: "sssH")
                .font(.system(.largeTitle, design: .monospaced).weight(.semibold))

            Text("Versie \(versionText)", comment: "Version line in the about window")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Een SSH-client voor Mac, iPad en iPhone.", comment: "Tagline in the about window")
                .padding(.top, 12)

            Text("Gemaakt door Rory Meijer", comment: "Author credit in the about window")
                .foregroundStyle(.secondary)

            Link(destination: URL(string: "https://github.com/rorymeijer/sssH")!) {
                Label {
                    Text(verbatim: "github.com/rorymeijer/sssH")
                } icon: {
                    Image(systemName: "curlybraces")
                }
            }
            .padding(.top, 4)
        }
        .padding(36)
        .multilineTextAlignment(.center)
        #if os(macOS)
        .fixedSize()
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    /// "0.1.0 (1)", from the bundle, so this never goes stale on a release.
    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// The real app icon rather than a lookalike. On iOS an asset catalog's
    /// app icon is not loadable by its catalog name, so it is read via the
    /// bundle's icon manifest, with a drawn fallback for when that fails.
    @ViewBuilder private var appIcon: some View {
        #if os(macOS)
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
        #else
        if let icon = UIImage.primaryAppIcon {
            Image(uiImage: icon)
                .resizable()
                .clipShape(RoundedRectangle(cornerRadius: 22))
        } else {
            RoundedRectangle(cornerRadius: 22)
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "terminal")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
        }
        #endif
    }
}

#if os(iOS)
private extension UIImage {
    /// The primary icon's largest rendition, via the Info.plist icon manifest.
    static var primaryAppIcon: UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last else { return nil }
        return UIImage(named: name)
    }
}
#endif
