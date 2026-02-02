// swift-tools-version: 5.9
import PackageDescription
import Foundation

let package = Package(
    name: "SwiftMsQuic",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "SwiftMsQuic", targets: ["SwiftMsQuic", "SwiftMsQuicHelper"])
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
        ),
        .target(
            name: "SwiftMsQuicHelper",
            dependencies: [
                .target(name: "SwiftMsQuic")
            ],
            path: "Sources/SwiftMsQuicHelper",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(["-strict-concurrency=minimal"]) 
            ]
        )
    ]
)
