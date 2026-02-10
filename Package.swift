// swift-tools-version: 5.9
import PackageDescription
import Foundation

let useDebugMsQuic = ProcessInfo.processInfo.environment["MSQUIC_DEBUG"] != nil
let msquicTargetName = useDebugMsQuic ? "MsQuicDebug" : "MsQuic"

let package = Package(
    name: "SwiftMsQuic",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "SwiftMsQuic", type: .dynamic, targets: [msquicTargetName, "SwiftMsQuicHelper"]),
        .library(name: "SwiftMsQuicStatic", type: .static, targets: [msquicTargetName, "SwiftMsQuicHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0")
    ],
    targets: [
        .binaryTarget(
            name: "MsQuic",
            url: "https://github.com/team-unstablers/msquic/releases/download/v2.5.6-tuvariant%2Binmemory-pem-r2/MsQuic-2.5.6-tuvariant+inmemory-pem-r2-RELEASE-darwin-multiarch-static-unsigned.zip",
            checksum: "08a7c2883c18e2c01b6df36bbec739d9400be240ed2396b0bb966f0be18c798e",
        ),
        .binaryTarget(
            name: "MsQuicDebug",
            url: "https://github.com/team-unstablers/msquic/releases/download/v2.5.6-tuvariant%2Binmemory-pem-r2/MsQuic-2.5.6-tuvariant+inmemory-pem-r2-DEBUG-darwin-multiarch-static-unsigned.zip",
            checksum: "a6b02d8969fbb1379b9b82fd9e75b66a5f20a1b71319552d8f35ba713e83f0e1",
        ),
        .target(
            name: "SwiftMsQuicOpenSSLUtils",
            dependencies: [
                .target(name: msquicTargetName)
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
                .target(name: msquicTargetName),
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
