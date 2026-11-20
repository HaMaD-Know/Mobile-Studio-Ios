// swift-tools-version:5.9
// Official Luau VM + compiler (vendored, see PATCHES.md), exposed to Swift through its C API.
import PackageDescription

let package = Package(
    name: "Luau",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "Luau", targets: ["Luau"])],
    targets: [
        .target(
            name: "Luau",
            path: "Sources/Luau",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("Common/include"),
                .headerSearchPath("Ast/include"),
                .headerSearchPath("Bytecode/include"),
                .headerSearchPath("Bytecode/src"),
                .headerSearchPath("Compiler/include"),
                .headerSearchPath("VM/src"),
                .unsafeFlags(["-Wno-everything"]),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
