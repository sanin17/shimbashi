// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "VoiceCore",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "VoiceCore", targets: ["VoiceCore"])
    ],
    targets: [
        .target(
            name: "VoiceCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VoiceCoreTests",
            dependencies: ["VoiceCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
