# swift-msquic

A Swift wrapper for [MsQuic](https://github.com/microsoft/msquic), providing prebuilt binaries and an idiomatic Swift API with async/await support.

This library simplifies the usage of the QUIC protocol in Swift applications on macOS and iOS, abstracting away the raw C API and manual memory management.

## Features

- **Swift Concurrency Support**: All asynchronous operations (connect, send, receive, etc.) are wrapped with `async/await` and `AsyncSequence`.
- **Memory Safety**: Class-based wrappers handle MsQuic handle lifetimes automatically using ARC (Automatic Reference Counting).
- **Prebuilt Binaries**: Includes `MsQuic.xcframework` (`v2.5.6-tuvariant`), so you don't need to build MsQuic from source.
- **iOS Compatible**: Modified to comply with iOS App Store guidelines (removed `dlopen` calls).
- **Stream Scheduling Controls**: Supports connection-level stream scheduling (`fifo` / `roundRobin`) and per-stream priority.

## Requirements

- Swift 6.0+ (Xcode 16+)
- macOS 13.0+
- iOS 16.0+

The package is compiled in Swift 6 language mode (`.v6`) with strict
concurrency enabled. It can still be consumed by projects that are
themselves in Swift 5 mode, as long as the toolchain is Swift 6.0 or
newer.

## Installation

Add `swift-msquic` to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/team-unstablers/swift-msquic.git", from: "2.0.0")
]
```

Then add `SwiftMsQuic` to your target dependencies:

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
import SwiftMsQuic

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

    // Optional: use round-robin scheduling across streams of the same priority
    try connection.setStreamSchedulingScheme(.roundRobin)
    
    // 3. Open Stream & Send Data
    do {
        let stream = try connection.openStream(flags: .none)
        try await stream.start()
        try stream.setPriority(0x9000) // 0xFFFF is highest priority

        try await stream.send(Data("Hello".utf8), flags: .fin)

        // 4. Receive Data
        for try await data in stream.receive {
            print("Received: \(String(decoding: data, as: UTF8.self))")
        }

        await stream.shutdown(flags: .graceful)
    }

    // 5. Shutdown Connection
    await connection.shutdown()
}
```

Locally opened streams should be released before you expect transport resources to be fully closed. `await connection.shutdown()` waits for the transport shutdown event, but `ConnectionClose` still happens from `deinit`.

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
        // Accept the connection and attach a stream handler. The first
        // closure parameter is `isolated (any Actor)?` (SE-0420) — use
        // `_` if you don't need to hop onto a specific actor.
        let connection = try info.accept(configuration: config) { _, conn, stream, flags in
            do {
                for try await data in stream.receive {
                    try await stream.send(data) // Echo back
                }
                await stream.shutdown(flags: .graceful)
            } catch {
                print("Stream error: \(error)")
            }
        }
        return connection
    }
    
    try listener.start(alpnBuffers: ["my-proto"], localAddress: QuicAddress(port: 4567))
    
    // Keep the server running...
    try await Task.sleep(nanoseconds: 100_000_000_000_000)
}
```

### 4. Stream Scheduling & Priority

`QuicConnection` supports connection-level stream scheduling:

```swift
try connection.setStreamSchedulingScheme(.fifo)       // default
try connection.setStreamSchedulingScheme(.roundRobin) // fairness for same-priority streams

let scheme = try connection.getStreamSchedulingScheme()
print("Current scheme: \(scheme)")
```

`QuicStream` supports per-stream send priority (`UInt16`, `0x0000...0xFFFF`):

```swift
try stream.setPriority(0xFFFF) // highest
let priority = try stream.getPriority()
print("Current stream priority: \(priority)")
```

## Debug Build

This package ships both **Release** and **Debug** (with MsQuic internal logging enabled) prebuilt binaries. By default, the Release binary is used.

To switch to the Debug binary, set the `MSQUIC_DEBUG` environment variable before building:

```bash
MSQUIC_DEBUG=1 swift build
```

> **Note**: This environment variable is evaluated at **package resolution time** (`Package.swift`), not at build time. Xcode resolves packages through its own process, so this method works reliably only with the Swift CLI (`swift build`, `swift test`, etc.).

## Migrating from 1.x → 2.0

v2.0.0 adopts Swift 6 strict concurrency and removes most of the raw C
types from the public API. The migration is mechanical — the following
are the breaking changes you will almost certainly have to touch:

### The Swift module is now `SwiftMsQuic`

The Swift target was renamed from `SwiftMsQuicHelper` to
`SwiftMsQuic`. The Swift Package Manager library products
(`SwiftMsQuic` / `SwiftMsQuicStatic`) keep their names — now the
product name and the importable module name line up.

```swift
// v1.x
import SwiftMsQuicHelper

// v2.0
import SwiftMsQuic
```

Your `Package.swift` dependency entry does not need to change: the
product was already called `SwiftMsQuic` in 1.x, so
`.product(name: "SwiftMsQuic", package: "swift-msquic")` keeps working.

### Accepting server-side connections

```swift
// v1.x — construct the connection directly from the raw HQUIC.
let connection = try QuicConnection(
    handle: info.connection,
    configuration: config
) { conn, stream, flags in
    // ...
}

// v2.0 — use the new `accept(...)` helper on NewConnectionInfo.
let connection = try info.accept(configuration: config) { _, conn, stream, flags in
    // ...
}
```

### `StreamHandler` gains an isolation parameter

The `StreamHandler` typealias now takes an `isolated (any Actor)?` as
its first parameter (SE-0420). Add a leading `_` (or a named
`isolation` parameter) to every existing handler closure:

```swift
// v1.x
{ conn, stream, flags in ... }

// v2.0
{ _, conn, stream, flags in ... }
```

### Events no longer carry raw C pointers

`QuicConnectionEvent.peerStreamStarted`'s associated value is now a
`QuicStream` wrapper instead of the raw `HQUIC`:

```swift
// v1.x
case .peerStreamStarted(let stream, let flags): // stream: HQUIC

// v2.0
case .peerStreamStarted(let stream, let flags): // stream: QuicStream
```

`QuicConnectionEvent.datagramSendStateChanged` and
`QuicStreamEvent.sendComplete` no longer expose the
`context: UnsafeMutableRawPointer?` field. The async send APIs
(`connection.sendDatagram(...)`, `stream.send(...)`) already return a
proper completion result, so the raw context field was redundant.

### `SwiftMsQuicAPI` is a namespace enum

`SwiftMsQuicAPI.shared` has been removed. `SwiftMsQuicAPI.MsQuic` — the
raw C API table — is now `internal`. Use the Swift wrappers instead
(they all call into `SwiftMsQuicAPI.MsQuic` via per-object `api`
accessors).

### Subclassing `QuicObject` is no longer allowed

`QuicObject` is now `public class` (non-`open`), meaning external
modules can still hold references to it but cannot subclass it. Build
your own higher-level actors on top of `QuicListener` /
`QuicConnection` / `QuicStream` instead.

### Upgrade checklist

1. Bump your dependency: `from: "2.0.0"`.
2. Replace every `import SwiftMsQuicHelper` with `import SwiftMsQuic`.
3. Replace `QuicConnection(handle: info.connection, configuration:)` with `info.accept(configuration:)`.
4. Add a leading `_ isolation` parameter to every `StreamHandler` closure.
5. Adjust pattern matches on `.peerStreamStarted` to take a `QuicStream`.
6. Drop any reference to the `context` field on `.datagramSendStateChanged` / `.sendComplete`.
7. Remove references to `SwiftMsQuicAPI.shared`.
8. Bump your Swift tools-version to 6.0, or keep Swift 5 mode and use a Swift 6.0+ toolchain.

## Important Notes

- **MsQuic Version**: The included binary is based on **MsQuic v2.5.6**.
- **Use SwiftMsQuic**: It is strongly recommended to use the `SwiftMsQuic` module instead of importing `MsQuic` directly. Swift's C Interop does not fully support C macros, making it impossible to access MsQuic status codes (which are macros) directly. `SwiftMsQuic` provides proper Swift wrappers (e.g., `QuicStatus`) to handle this.
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
