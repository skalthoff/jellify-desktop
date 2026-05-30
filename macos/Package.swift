// swift-package-manager manifest for Lyrebird (macOS app target).
//
// NOTE: this is a convenience manifest for `swift build`/`swift test` in CI
// and headless dev. The shipping app is built via the Xcode project, which
// has its own target/membership rules. Keep the two in rough sync.
//
// The `LyrebirdCore` binary target points at the committed xcframework so
// `swift build` links the same Rust core the app uses.
import PackageDescription

let package = Package(
    name: "lyrebird",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Lyrebird", targets: ["Lyrebird"]),
    ],
    targets: [
        .target(
            name: "Lyrebird",
            dependencies: ["LyrebirdCore"],
            path: "Sources/Lyrebird"
        ),
        .binaryTarget(
            name: "LyrebirdCore",
            // Built by Scripts/build-core.sh; committed so CI/dev `swift build`
            // links without a Rust toolchain. Regenerate after core changes.
            path: "../Lyrebird.xcframework"
        ),
        .testTarget(
            name: "MiniPlayerStateTests",
            dependencies: ["Lyrebird"],
            path: "Tests/LyrebirdTests"
        ),
    ]
)
