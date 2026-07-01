// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "screenmonger",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "screenmonger",
            path: "Sources/screenmonger"
        ),
        .testTarget(
            name: "screenmongerTests",
            dependencies: ["screenmonger"],
            path: "Tests/screenmongerTests"
        )
    ],
    // Phase 1 uses language mode 5 to keep the AppKit/C-callback glue simple.
    // We'll tighten to strict Swift 6 concurrency once the DisplayManager actor lands.
    swiftLanguageModes: [.v5]
)
