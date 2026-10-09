// swift-tools-version: 6.2
// ClipperKit: everything except the app's UI. The app target and the `clipper` CLI both build on it.
import PackageDescription

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
        ]),

        .testTarget(name: "ClipperCoreTests", dependencies: ["ClipperCore"]),
        .testTarget(name: "ClipperAutomationTests", dependencies: ["ClipperAutomation"]),
        .testTarget(name: "ClipperEngineTests", dependencies: ["ClipperEngine"]),
        .testTarget(name: "ClipperAnalysisTests", dependencies: ["ClipperAnalysis"]),
        .testTarget(name: "ClipperLibraryTests", dependencies: ["ClipperLibrary"]),
    ]
)
