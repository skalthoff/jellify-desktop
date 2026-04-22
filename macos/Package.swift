// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jellify",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Jellify", targets: ["Jellify"]),
        .executable(name: "SmokeTest", targets: ["SmokeTest"]),
        .library(name: "JellifyCore", targets: ["JellifyCore"]),
        .library(name: "JellifyAudio", targets: ["JellifyAudio"]),
    ],
    dependencies: [
        // Nuke powers artwork loading (disk cache, request coalescing, background
        // decoding, decode-time downscaling). Replaces SwiftUI.AsyncImage which had
        // no caching and decoded at source resolution — #426 / #427.
        .package(url: "https://github.com/kean/Nuke.git", from: "13.0.0"),
        // Sparkle 2 handles the self-update feed (Ed25519-signed appcast,
        // in-app "Check for Updates…", scheduled background checks).
        // Feed URL + public key live in Info.plist; the release workflow
        // substitutes the public key at build time. See #183/#184/#188.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .binaryTarget(
            name: "JellifyCoreFFI",
            path: "Jellify.xcframework"
        ),
        .target(
            name: "JellifyCore",
            dependencies: ["JellifyCoreFFI"],
            path: "Sources/JellifyCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "JellifyAudio",
            dependencies: ["JellifyCore"],
            path: "Sources/JellifyAudio",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "Jellify",
            dependencies: [
                "JellifyCore",
                "JellifyAudio",
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "NukeUI", package: "Nuke"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Jellify",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AudioUnit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .executableTarget(
            name: "SmokeTest",
            dependencies: ["JellifyCore", "JellifyAudio"],
            path: "Sources/SmokeTest",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AudioUnit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
    ]
)
