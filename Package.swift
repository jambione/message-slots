// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MessageSlots",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        // The deterministic game engine. No UI, no Apple-only frameworks in the
        // required path — so it builds and tests anywhere, including CI on Linux.
        .library(name: "GameCore", targets: ["GameCore"])
    ],
    targets: [
        .target(
            name: "GameCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "GameCoreTests",
            dependencies: ["GameCore"]
        )
    ]
)
