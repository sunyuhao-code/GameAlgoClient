// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GameAlgoClient",
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
        .target(
            name: "GameAlgoSDK",
            path: "ios/Sources/GameAlgoSDK"
        ),
        .testTarget(
            name: "GameAlgoSDKTests",
            dependencies: ["GameAlgoSDK"],
            path: "ios/Tests/GameAlgoSDKTests"
        ),
    ]
)
