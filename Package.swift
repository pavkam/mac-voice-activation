// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VoiceActivation",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VoiceActivationCore", targets: ["VoiceActivationCore"]),
        .executable(name: "VoiceActivation", targets: ["VoiceActivationApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing", revision: "swift-6.2.2-RELEASE"),
    ],
    targets: [
        .target(name: "VoiceActivationCore"),
        .executableTarget(
            name: "VoiceActivationApp",
            dependencies: [
                "VoiceActivationCore",
            ],
            exclude: ["Resources/Info.plist"]),
        .testTarget(
            name: "VoiceActivationCoreTests",
            dependencies: [
                "VoiceActivationCore",
                .product(name: "Testing", package: "swift-testing"),
            ]),
        .testTarget(
            name: "VoiceActivationAppTests",
            dependencies: [
                "VoiceActivationApp",
                .product(name: "Testing", package: "swift-testing"),
            ]),
    ])
