# swift-msquic

A Swift wrapper for [MsQuic](https://github.com/microsoft/msquic), providing prebuilt binaries and an idiomatic Swift API with async/await support.

This library simplifies the usage of the QUIC protocol in Swift applications on macOS and iOS, abstracting away the raw C API and manual memory management.

## Features

- **Swift Concurrency Support**: All asynchronous operations (connect, send, receive, etc.) are wrapped with `async/await` and `AsyncSequence`.
- **Memory Safety**: Class-based wrappers handle MsQuic handle lifetimes automatically using ARC (Automatic Reference Counting).
- **Prebuilt Binaries**: Includes `MsQuic.xcframework` (`v2.5.6-tuvariant`), so you don't need to build MsQuic from source.
- **iOS Compatible**: Modified to comply with iOS App Store guidelines (removed `dlopen` calls).

## Requirements

- Swift 5.9+
- macOS 13.0+
- iOS 16.0+

## Installation

Add `swift-msquic` to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/team-unstablers/swift-msquic.git", from: "1.0.5")
]
```

Then add `SwiftMsQuicHelper` to your target dependencies:

```swift
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "SwiftMsQuic", package: "swift-msquic")
        ]
    )
]
```

## Usage

### 1. Initialize API

You must initialize the MsQuic API before using it.

```swift
import SwiftMsQuicHelper

// Initialize
try SwiftMsQuicAPI.open().throwIfFailed()

// Cleanup when done
defer { SwiftMsQuicAPI.close() }
```

### 2. Client Example

```swift
func runClient() async throws {
    // 1. Create Registration & Configuration
    let reg = try QuicRegistration(config: .init(appName: "MyClient", executionProfile: .lowLatency))
    let config = try QuicConfiguration(registration: reg, alpnBuffers: ["my-proto"])
    
    // Disable certificate validation for testing (NOT for production)
    try config.loadCredential(.init(type: .none, flags: [.client, .noCertificateValidation]))
    
    // 2. Connect
    let connection = try QuicConnection(registration: reg)
    try await connection.start(configuration: config, serverName: "localhost", serverPort: 4567)
    
    // 3. Open Stream & Send Data
    let stream = try connection.openStream(flags: .none)
    try await stream.start()
    
    try await stream.send(Data("Hello".utf8), flags: .fin)
    
    // 4. Receive Data
    for try await data in stream.receive {
        print("Received: \(String(decoding: data, as: UTF8.self))")
    }
}
```

### 3. Server Example

```swift
func runServer() async throws {
    let reg = try QuicRegistration(config: .init(appName: "MyServer", executionProfile: .lowLatency))
    
    // Configure settings (e.g., timeouts, peer stream counts)
    var settings = QuicSettings()
    settings.peerBidiStreamCount = 100
    settings.idleTimeoutMs = 30000 
    
    let config = try QuicConfiguration(registration: reg, alpnBuffers: ["my-proto"], settings: settings)
    
    // Load Server Certificate
    try config.loadCredential(.init(
        type: .certificateFile(certPath: "server.crt", keyPath: "server.key"),
        flags: []
    ))
    
    let listener = try QuicListener(registration: reg)
    
    // Handle new connections
    listener.onNewConnection { listener, info in
        let connection = try QuicConnection(handle: info.connection, configuration: config) { conn, stream in
            // Handle new streams
            Task {
                for try await data in stream.receive {
                    // Echo back
                    try await stream.send(data)
                }
                stream.shutdownSend()
            }
        }
        return connection
    }
    
    try listener.start(alpnBuffers: ["my-proto"], localAddress: QuicAddress(port: 4567))
    
    // Keep the server running...
    try await Task.sleep(nanoseconds: 100_000_000_000_000)
}
```

## Important Notes

- **MsQuic Version**: The included binary is based on **MsQuic v2.5.7-rc**.
- **Use SwiftMsQuicHelper**: It is strongly recommended to use the `SwiftMsQuicHelper` module instead of importing `MsQuic` directly. Swift's C Interop does not fully support C macros, making it impossible to access MsQuic status codes (which are macros) directly. `SwiftMsQuicHelper` provides proper Swift wrappers (e.g., `QuicStatus`) to handle this.
- **Modifications**: This repository uses a fork of MsQuic maintained by **Team Unstablers Inc.** with the following change:
    - Removed `dlopen(3)` calls in `quic_bugcheck` to ensure compliance with iOS App Store review guidelines.

## 'Vibe Coding' Notice

Part of this wrapper code was written via "Vibe Coding" using Large Language Models.
The following agents/models were used:

- **Claude Code**: Claude Opus 4.5
- **OpenAI Codex**: gpt-5.2-codex (xhigh)
- **Google Gemini CLI**: Google Gemini 3 Pro (Preview)

## Related Projects

- [`team-unstablers/msquic`](https://github.com/team-unstablers/msquic) - Source code of the modified MsQuic.
- [`team-unstablers/swift-msquic-backstage`](https://github.com/team-unstablers/swift-msquic-backstage) - Build scripts for macOS/iOS.

## Author

- Gyuhwan Park★ (Team Unstablers Inc.) <unstabler@unstabler.pl>
