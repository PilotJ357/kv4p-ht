// swift-tools-version: 5.9
import PackageDescription

// Codec2 1.2.0 (LGPL-2.1), built for CODEC2_MODE_1300 only — the mode used by
// FreeDV 2400B on the KV4P radio. See README.md for how the sources were
// vendored and how to refresh them.
let package = Package(
    name: "Codec2",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Codec2Swift", targets: ["Codec2Swift"]),
    ],
    targets: [
        .target(
            name: "CCodec2",
            path: "Sources/CCodec2",
            cSettings: [
                .define("CODEC2_MODE_EN_DEFAULT", to: "0"),
                .define("CODEC2_MODE_1300_EN", to: "1"),
                // Upstream code; don't drown the app build in its warnings.
                .unsafeFlags(["-w"]),
            ],
            linkerSettings: [.linkedLibrary("m")]
        ),
        .target(
            name: "Codec2Swift",
            dependencies: ["CCodec2"],
            path: "Sources/Codec2Swift"
        ),
        .testTarget(
            name: "Codec2SwiftTests",
            dependencies: ["Codec2Swift"],
            path: "Tests/Codec2SwiftTests"
        ),
    ]
)
