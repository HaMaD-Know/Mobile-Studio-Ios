// swift-tools-version:5.9
// StudioCore: the platform-independent half of Mobile Studio.
//  - StudioCore:   data model, file formats, undo (Android model/, format/, core/)
//  - StudioScript: Luau scripting runtime, Roblox API, Play mode engine (Android lua/, engine/)
import PackageDescription

let package = Package(
    name: "StudioCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "StudioCore", targets: ["StudioCore"]),
        .library(name: "StudioScript", targets: ["StudioScript"]),
    ],
    dependencies: [
        // Roblox binary files may use ZSTD-compressed chunks (Android used zstd-jni).
        .package(url: "https://github.com/facebook/zstd.git", from: "1.5.6"),
        // Vendored official Luau VM + compiler (Android used LuaJ + a Luau->Lua transpiler).
        .package(path: "../Luau"),
    ],
    targets: [
        .target(
            name: "StudioCore",
            dependencies: [.product(name: "libzstd", package: "zstd")]
        ),
        .target(
            name: "StudioScript",
            dependencies: ["StudioCore", .product(name: "Luau", package: "Luau")]
        ),
        .testTarget(name: "StudioCoreTests", dependencies: ["StudioCore"]),
        .testTarget(name: "StudioScriptTests", dependencies: ["StudioScript"]),
    ]
)
