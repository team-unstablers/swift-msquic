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
        .library(name: "SwiftMsQuic", type: .dynamic, targets: ["MsQuic", "SwiftMsQuicHelper"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0")
    ],
    targets: [
        .binaryTarget(
            name: "MsQuic",
            url: "https://github.com/team-unstablers/msquic/releases/download/v2.5.6-tuvariant%2Binmemory-pem/MsQuic-2.5.6-tuvariant+inmemory-pem-darwin-multiarch-static-unsigned.zip",
            checksum: "a4cf76fd11849eb7013f0052682ed294c92304943712a2ca4325fe79164e708e",
        ),
        .target(
            name: "SwiftMsQuicOpenSSLUtils",
            dependencies: [
                .target(name: "MsQuic")
            ],
            path: "Sources/SwiftMsQuicOpenSSLUtils",
            publicHeadersPath: "Headers",
            cSettings: [
                .headerSearchPath("."),
            ],
        ),
        .target(
            name: "SwiftMsQuicHelper",
            dependencies: [
                .target(name: "MsQuic"),
                .target(name: "SwiftMsQuicOpenSSLUtils"),
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
