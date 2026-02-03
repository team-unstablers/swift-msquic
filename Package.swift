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
    dependencies: [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0")
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
            swiftSettings: []
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
