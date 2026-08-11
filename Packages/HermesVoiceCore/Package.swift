// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesVoiceCore",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v11)],
    products: [
        .library(name: "HermesKit", targets: ["HermesKit"]),
        .library(name: "VoiceEngine", targets: ["VoiceEngine"]),
    ],
    targets: [
        .target(name: "HermesKit"),
        .target(name: "VoiceEngine", dependencies: ["HermesKit"]),
        .testTarget(name: "HermesKitTests", dependencies: ["HermesKit"]),
        .testTarget(name: "VoiceEngineTests", dependencies: ["VoiceEngine"]),
    ]
)
