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
        .binaryTarget(
            name: "GameAlgoScriptRuntime",
            path: "ios/GameAlgoScriptRuntime.xcframework"
        ),
        .target(
            name: "GameAlgoSDK",
            dependencies: ["GameAlgoScriptRuntime"],
            path: "ios/Sources/GameAlgoSDK"
        ),
        .testTarget(
            name: "GameAlgoSDKTests",
            dependencies: ["GameAlgoSDK"],
            path: "ios/Tests/GameAlgoSDKTests"
        ),
    ]
)
