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
        .library(name: "SwiftMsQuic", targets: ["MsQuic", "SwiftMsQuicHelper"])
    ],
    targets: [
        .binaryTarget(
            name: "MsQuic",
            path: "./dist/MsQuic.xcframework"
        ),
        .target(
            name: "SwiftMsQuicHelper",
            dependencies: [
                .target(name: "MsQuic")
            ],
            path: "Sources/SwiftMsQuicHelper",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=minimal"]) 
            ]
        ),
        .executableTarget(
            name: "SwiftMsQuicExample",
            dependencies: ["SwiftMsQuicHelper"],
            path: "Sources/SwiftMsQuicExample",
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        )
    ]
)
