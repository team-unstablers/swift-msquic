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
            url: "https://github.com/team-unstablers/msquic/releases/download/v2.5.6-tuvariant%2Binmemory-pem-r2/MsQuic-2.5.6-tuvariant+inmemory-pem-r2-RELEASE-darwin-multiarch-static-unsigned-rebuild.zip",
            checksum: "be40ef8bfd6f1e68b364e8f141b2e678d0cd8c7be47f6d2281ab09e4c2297c48",
        ),
        .binaryTarget(
            name: "MsQuicDebug",
            url: "https://github.com/team-unstablers/msquic/releases/download/v2.5.6-tuvariant%2Binmemory-pem-r2/MsQuic-2.5.6-tuvariant+inmemory-pem-r2-DEBUG-darwin-multiarch-static-unsigned-rebuild.zip",
            checksum: "700bde4df192d105fbfa7368d744d9f4ac2dd70a57f093028b564dce78bb76b1",
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
