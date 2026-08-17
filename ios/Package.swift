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
        .binaryTarget(
            name: "GameAlgoScriptRuntime",
            path: "GameAlgoScriptRuntime.xcframework"
        ),
        .target(
            name: "GameAlgoSDK",
            dependencies: ["GameAlgoScriptRuntime"]
        ),
        .testTarget(
            name: "GameAlgoSDKTests",
            dependencies: ["GameAlgoSDK"]
        ),
    ]
)
