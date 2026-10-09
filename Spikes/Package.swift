// swift-tools-version: 6.2
// Phase 0 de-risking spikes. Throwaway code: what survives moves into Packages/ClipperKit in Phase 1.
import PackageDescription

let package = Package(
    name: "ClipperSpikes",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "SpikeKit"),
        .executableTarget(name: "s1-parity", dependencies: ["SpikeKit"]),
        .executableTarget(name: "s2-hdr", dependencies: ["SpikeKit"]),
        .executableTarget(name: "s3-asr", dependencies: ["SpikeKit"]),
        .executableTarget(name: "s4-timeline", dependencies: ["SpikeKit"]),
        .executableTarget(name: "s5-longmedia", dependencies: ["SpikeKit"]),
    ]
)
