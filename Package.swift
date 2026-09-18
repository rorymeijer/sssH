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
//                         protocols, plus the algorithms NIOSSH omits (RSA,
//                         diffie-hellman-group14, AES128-CTR). Replaceable:
//                         nothing above it may import it other than the one
//                         place that constructs a transport.
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
        // A fork. sssh needs changes inside the library — keyboard-interactive
        // authentication, and RFC 8332's separation of the RSA key-blob name
        // from the signature algorithm name — and both are written to be
        // upstreamed. See Vendor/README.md.
        .package(path: "Vendor/swift-nio-ssh"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.62.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "2.0.0" ..< "3.0.0"),
        // Only for RSA's CRT parameters and the group-14 modular exponentiation.
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0"),
    ],
    targets: [
        .target(
            name: "ssshCrypto",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                // Only for RSA's CRT exponents, which OpenSSH does not store.
                .product(name: "BigInt", package: "BigInt"),
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
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                // RSA signing, which NIOSSH deliberately omits.
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "BigInt", package: "BigInt"),
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
            dependencies: [
                "ssshCore",
                "ssshTransportNIOSSH",
                // The SFTP codec deals in ByteBuffer, so its tests do too.
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
    ]
)
