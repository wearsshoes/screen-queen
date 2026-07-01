// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Silkscreen",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Silkscreen",
            path: "Sources/Silkscreen"
        ),
        .testTarget(
            name: "SilkscreenTests",
            dependencies: ["Silkscreen"],
            path: "Tests/SilkscreenTests"
        )
    ],
    // Phase 1 uses language mode 5 to keep the AppKit/C-callback glue simple.
    // We'll tighten to strict Swift 6 concurrency once the DisplayManager actor lands.
    swiftLanguageModes: [.v5]
)
