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
            dependencies: ["JellifyCore", "JellifyAudio"],
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
