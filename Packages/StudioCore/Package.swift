// swift-tools-version:5.9
// StudioCore: the platform-independent half of Mobile Studio (data model, file formats, undo).
// Ported from the Android app's com.exampletest.mobilestudiotest.{model,format,core} packages.
import PackageDescription

let package = Package(
    name: "StudioCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "StudioCore", targets: ["StudioCore"]),
    ],
    dependencies: [
        // Roblox binary files may use ZSTD-compressed chunks (Android used zstd-jni).
        .package(url: "https://github.com/facebook/zstd.git", from: "1.5.6"),
    ],
    targets: [
        .target(
            name: "StudioCore",
            dependencies: [.product(name: "libzstd", package: "zstd")]
        ),
        .testTarget(name: "StudioCoreTests", dependencies: ["StudioCore"]),
    ]
)
