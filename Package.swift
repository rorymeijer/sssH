// swift-tools-version:5.9
import PackageDescription

// The sssh transport stack lives in SwiftPM so that it can be built and tested
// on Linux in CI, independently of the SwiftUI app targets (which live in the
// Xcode project and are added in Phase 1).
//
// Layering (see docs/ARCHITECTURE.md):
//
//   ssshCrypto            the primitives swift-crypto does not expose and the
//                         openssh-key-v1 parser built on them. No SwiftNIO.
//   ssshCore              pure Swift. Protocols + value types. No SwiftNIO, no
//                         Citadel, no platform UI. This is what the app layer
//                         imports.
//   ssshTransportNIOSSH   the swift-nio-ssh backed implementation of those
//                         protocols, with Citadel supplying RSA, the
//                         diffie-hellman-group14 exchanges, AES128-CTR and
//                         OpenSSH key parsing. Replaceable: nothing above it
//                         may import it other than the one place that
//                         constructs a transport.
//   ssshPTYSpike          the Phase 0 interactive-PTY harness (§3 of the brief).
//
let package = Package(
    name: "sssh",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ssshCrypto", targets: ["ssshCrypto"]),
        .library(name: "ssshCore", targets: ["ssshCore"]),
        .library(name: "ssshTransportNIOSSH", targets: ["ssshTransportNIOSSH"]),
        .executable(name: "sssh-ptyspike", targets: ["ssshPTYSpike"]),
    ],
    dependencies: [
        // Pinned to the last tag published by Citadel's own maintainer. `main`
        // currently points swift-nio-ssh at a third-party fork
        // (Wellz26/swift-nio-ssh), which we do not want in the dependency graph
        // of a credential-handling app. See docs/PHASE-0-BACKEND-DECISION.md.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.9.2"),
        // The same fork Citadel 0.9.2 resolves, named here because the
        // transport imports NIOSSH directly rather than only through Citadel.
        .package(url: "https://github.com/Joannis/swift-nio-ssh.git", "0.3.2" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.62.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        // Mirrors Citadel's own range so SwiftPM resolves a single version.
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0" ..< "2.1.0"),
    ],
    targets: [
        .target(
            name: "ssshCrypto",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "ssshCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "ssshTransportNIOSSH",
            dependencies: [
                "ssshCore",
                "ssshCrypto",
                // swift-nio-ssh is driven directly (see
                // docs/PHASE-0-BACKEND-DECISION.md); Citadel is used for the
                // algorithms and key parsing NIOSSH lacks.
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "ssshPTYSpike",
            dependencies: [
                "ssshCore",
                "ssshTransportNIOSSH",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "ssshCryptoTests",
            dependencies: ["ssshCrypto"]
        ),
        .testTarget(
            name: "ssshCoreTests",
            dependencies: ["ssshCore"]
        ),
        .testTarget(
            name: "ssshTransportNIOSSHTests",
            dependencies: ["ssshCore", "ssshTransportNIOSSH"]
        ),
    ]
)
