// swift-tools-version: 5.8

import PackageDescription

let package = Package(
    name: "MediaPipeTasks",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "MediaPipeTasksCommon",
            targets: ["MediaPipeTasksCommon"]
        ),
        .library(
            name: "MediaPipeTasksVision",
            targets: [
                "MediaPipeTasksVision",
                "MediaPipeTasksCommon",
            ]
        ),
        .library(
            name: "MediaPipeTasksText",
            targets: [
                "MediaPipeTasksText",
                "MediaPipeTasksCommon",
            ]
        ),
        .library(
            name: "MediaPipeTasksAudio",
            targets: [
                "MediaPipeTasksAudio",
                "MediaPipeTasksCommon",
            ]
        ),
        .library(
            name: "MediaPipeTasksRetrieval",
            targets: [
                "MediaPipeTasksRetrieval",
                "MediaPipeTasksCommon",
            ]
        ),
        .library(
            name: "MediaPipeTasksDecision",
            targets: [
                "MediaPipeTasksDecision",
                "MediaPipeTasksCommon",
            ]
        ),
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "MediaPipeTasksCommonBinary",
            path: "Binaries/MediaPipeTasksCommon-1.1.1.xcframework.zip"
        ),
        .binaryTarget(
            name: "MediaPipeTaskGraphsBinary",
            path: "Binaries/MediaPipeTaskGraphs-1.1.1.xcframework.zip"
        ),
        .binaryTarget(
            name: "MediaPipeTasksVision",
            path: "Binaries/MediaPipeTasksVision-1.1.1.xcframework.zip"
        ),
        .binaryTarget(
            name: "MediaPipeTasksText",
            path: "Binaries/MediaPipeTasksText-1.1.1.xcframework.zip"
        ),
        .binaryTarget(
            name: "MediaPipeTasksAudio",
            path: "Binaries/MediaPipeTasksAudio-1.1.1.xcframework.zip"
        ),
        .binaryTarget(
            name: "MediaPipeTasksRetrieval",
            path: "Binaries/MediaPipeTasksRetrieval-1.1.1.xcframework.zip"
        ),
        .binaryTarget(
            name: "MediaPipeTasksDecision",
            path: "Binaries/MediaPipeTasksDecision-1.1.1.xcframework.zip"
        ),
        .target(
            name: "MediaPipeTasksCommon",
            dependencies: [
                "MediaPipeTasksCommonBinary",
                "MediaPipeTaskGraphsBinary",
                "MediaPipeTasksVision",
                "MediaPipeTasksText",
                "MediaPipeTasksAudio",
                "MediaPipeTasksRetrieval",
                "MediaPipeTasksDecision",
            ],
            linkerSettings: [
                // Note: -all_load is required to prevent the Apple linker
                // from stripping C++ static calculator registration
                // constructors (REGISTER_CALCULATOR) in
                // MediaPipeTaskGraphsBinary. Downstream libraries wrapping
                // MediaPipeTasks in a remote SPM package must reference this
                // package by branch/revision or local path due to Apple's
                // .unsafeFlags restriction.
                .unsafeFlags(["-Xlinker", "-all_load"]),
                .linkedLibrary("c++"),
                // Required by MPPSqliteVectorStore in MediaPipeTasksRetrieval.
                .linkedLibrary("sqlite3"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("QuartzCore"),
            ]
        ),
    ]
)
