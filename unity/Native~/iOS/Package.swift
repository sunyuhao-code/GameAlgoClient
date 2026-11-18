// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GamePropelUnity",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "GamePropelUnity", type: .dynamic, targets: ["GamePropelUnity"])],
    dependencies: [.package(name: "GameAlgoClient", path: "../../..")],
    targets: [
        .target(name: "GamePropelUnity", dependencies: [.product(name: "GameAlgoSDK", package: "GameAlgoClient")]),
        .testTarget(name: "GamePropelUnityTests", dependencies: ["GamePropelUnity", .product(name: "GameAlgoSDK", package: "GameAlgoClient")])
    ]
)
