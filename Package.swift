// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PaceNote",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "PaceNoteCore", targets: ["PaceNoteCore"]),
        .executable(name: "PaceNote", targets: ["PaceNoteApp"]),
    ],
    targets: [
        .target(
            name: "PaceNoteCore",
            path: "Sources/PaceNoteCore",
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "PaceNoteApp",
            dependencies: ["PaceNoteCore"],
            path: "Sources/PaceNoteApp"
        ),
        .testTarget(
            name: "PaceNoteCoreTests",
            dependencies: ["PaceNoteCore"],
            path: "Tests/PaceNoteCoreTests"
        ),
        .testTarget(
            name: "PaceNoteAppTests",
            dependencies: ["PaceNoteApp", "PaceNoteCore"],
            path: "Tests/PaceNoteAppTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
