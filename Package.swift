// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenQueen",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScreenQueen",
            path: "Sources/ScreenQueen",
            resources: [.copy("Fonts")]
        ),
        .testTarget(
            name: "ScreenQueenTests",
            dependencies: ["ScreenQueen"],
            path: "Tests/ScreenQueenTests"
        )
    ],
    // Phase 1 uses language mode 5 to keep the AppKit/C-callback glue simple.
    // We'll tighten to strict Swift 6 concurrency once the DisplayManager actor lands.
    swiftLanguageModes: [.v5]
)
