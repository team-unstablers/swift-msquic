// swift-tools-version: 6.2
import PackageDescription
import Foundation

let package = Package(
    name: "SwiftMsQuic",
    platforms: [
        .macOS(.v11),
        .iOS(.v14)
    ],
    products: [
        .library(name: "SwiftMsQuic", targets: ["SwiftMsQuic"])
    ],
    targets: [
        .plugin(
            name: "PrebuiltLibraryInjector",
            capability: .buildTool(),
        ),
        .target(
            name: "SwiftMsQuic",
            path: "Sources/SwiftMsQuic",
            publicHeadersPath: "msquic",
            cxxSettings: [
                .define("QUIC_BUILD_STATIC"),
                .unsafeFlags(["-Wno-module-import-in-extern-c"])
            ],
            linkerSettings: [
                .linkedLibrary("msquic", .when(platforms: [.macOS, .iOS])),
                .linkedFramework("CoreFoundation", .when(platforms: [.macOS, .iOS])),
                .linkedFramework("Security", .when(platforms: [.macOS, .iOS])),
            ],
            plugins: [
                "PrebuiltLibraryInjector"
            ]
        )
    ]
)
