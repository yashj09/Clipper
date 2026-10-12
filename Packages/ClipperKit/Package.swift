// swift-tools-version: 6.2
// ClipperKit: everything except the app's UI. The app target and the `clipper` CLI both build on it.
import Foundation
import PackageDescription

/// The CLI embeds an Info.plist (bundle identifier) so system services that resolve per-app state — on-device
/// Translation language models, speech assets — treat it like an app.
let cliInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Sources/clipper/Info.plist").path

/// SwiftPM records the *deployment target* as the binary's SDK version (LC_BUILD_VERSION sdk 26.0) instead of the SDK it
/// actually built with. System frameworks gate behaviour on the linked SDK: e.g. on macOS 27 the Translation framework
/// reports installed language pairs as not installed to "SDK 26" clients. Keep the 26.0 minimum, record the real SDK.
/// (Xcode-built targets, like the app, are unaffected.) Override with CLIPPER_SDK_VERSION when building with another SDK.
let sdkVersion = ProcessInfo.processInfo.environment["CLIPPER_SDK_VERSION"] ?? "27.0"
let platformVersionFlags = ["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "26.0", "-Xlinker", sdkVersion]

let package = Package(
    name: "ClipperKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ClipperCore", targets: ["ClipperCore"]),
        .library(name: "ClipperEngine", targets: ["ClipperEngine"]),
        .library(name: "ClipperAnalysis", targets: ["ClipperAnalysis"]),
        .library(name: "ClipperAutomation", targets: ["ClipperAutomation"]),
        .library(name: "ClipperLibrary", targets: ["ClipperLibrary"]),
        .executable(name: "clipper", targets: ["clipper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Pure model: timeline, templates, edit commands, analysis artifacts. Foundation only.
        .target(name: "ClipperCore"),
        // Pure draft passes: (assets + analysis + template + settings) → Timeline. No I/O.
        .target(name: "ClipperAutomation", dependencies: ["ClipperCore"]),
        // AVFoundation/Metal: probe, composition builder, compositor, text, export, loudness, scheduling.
        .target(name: "ClipperEngine", dependencies: ["ClipperCore"]),
        // Speech, Vision, DSP analyzers producing ClipperCore artifacts.
        .target(name: "ClipperAnalysis", dependencies: ["ClipperCore", "ClipperEngine"]),
        // .clipperlib bundle: GRDB index, project/template documents, media, caches, settings.
        .target(name: "ClipperLibrary", dependencies: ["ClipperCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "clipper", dependencies: [
            "ClipperCore", "ClipperEngine", "ClipperAnalysis", "ClipperAutomation", "ClipperLibrary",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ], exclude: ["Info.plist"],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", cliInfoPlist]
                                      + platformVersionFlags)]),

        .testTarget(name: "ClipperCoreTests", dependencies: ["ClipperCore"]),
        .testTarget(name: "ClipperAutomationTests", dependencies: ["ClipperAutomation"]),
        .testTarget(name: "ClipperEngineTests", dependencies: ["ClipperEngine"]),
        .testTarget(name: "ClipperAnalysisTests", dependencies: ["ClipperAnalysis"]),
        .testTarget(name: "ClipperLibraryTests", dependencies: ["ClipperLibrary"]),
    ]
)
