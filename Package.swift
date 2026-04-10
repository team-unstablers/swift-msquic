// swift-tools-version: 6.0
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
            url: "https://github.com/team-unstablers/msquic/releases/download/v2.5.6-tuvariant%2B260410/MsQuic-2.5.6-tuvariant+260410-RELEASE-darwin-multiarch-static-unsigned.zip",
            checksum: "ed33b891aa22e99f725f946ea232a24fdfaa1b971b27c9b8be43031a1f9f35f9",
        ),
        .binaryTarget(
            name: "MsQuicDebug",
            url: "https://github.com/team-unstablers/msquic/releases/download/v2.5.6-tuvariant%2B260410/MsQuic-2.5.6-tuvariant+260410-DEBUG-darwin-multiarch-static-unsigned.zip",
            checksum: "37e0bccb528c9beec8dfeb7e67924f1d86a00f982c2227ce358dd3e0ca0fe4ae",
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
    ],
    swiftLanguageModes: [.v6]
)
