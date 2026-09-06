// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "VoiceInput",
            path: "Sources/VoiceInput",
            resources: [.copy("Resources/cursor-polish.mjs"), .copy("Resources/provider-models.mjs")],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "VoiceInputTests",
            dependencies: ["VoiceInput"],
            path: "Tests/VoiceInputTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
