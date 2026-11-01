// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "KariNative", defaultLocalization: "en", platforms: [.iOS(.v17)],
    products: [.library(name: "KariNative", targets: ["KariNative"])],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"), .package(path: "Vendor/GoogleSignIn-iOS"), .package(path: "Vendor/mediapipe")],
    targets: [.binaryTarget(name: "llama", path: "Vendor/llama.xcframework"), .target(name: "KariNative", dependencies: ["llama", .product(name: "ZIPFoundation", package: "ZIPFoundation"), .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"), .product(name: "MediaPipeTasksVision", package: "mediapipe")],
                      resources: [.copy("Resources/Face"), .copy("Resources/Models"), .process("Resources/LiveSetup.json"), .process("Resources/IdleScenes.json"), .process("Resources/en.lproj"), .process("Resources/zh-Hans.lproj")])]
)
