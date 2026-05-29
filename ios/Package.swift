// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GameAlgoIOS",
    platforms: [
        .iOS(.v13),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "GameAlgoSDK",
            targets: ["GameAlgoSDK"]
        ),
    ],
    targets: [
        .target(name: "GameAlgoSDK"),
        .testTarget(
            name: "GameAlgoSDKTests",
            dependencies: ["GameAlgoSDK"]
        ),
    ]
)
