# Getting Started

Learn how to set up and use SwiftMsQuicHelper for QUIC protocol communication.

## Overview

This guide walks you through initializing MsQuic, creating a client connection, and setting up a server listener.

## Initialize MsQuic

Before using any SwiftMsQuicHelper APIs, you must initialize the MsQuic library:

```swift
import SwiftMsQuicHelper

// Open the MsQuic library
try SwiftMsQuicAPI.open().throwIfFailed()

// When done, close it (typically in a defer block)
defer { SwiftMsQuicAPI.close() }
```

## Create a Client Connection

Here's how to connect to a QUIC server and send data:

```swift
// Create a registration (required for all MsQuic operations)
let registration = try QuicRegistration(config: .init(
    appName: "MyQuicClient",
    executionProfile: .lowLatency
))

// Create a configuration with ALPN
let configuration = try QuicConfiguration(
    registration: registration,
    alpnBuffers: ["my-protocol"]
)

// For testing without certificate validation
try configuration.loadCredential(.init(
    type: .none,
    flags: [.client, .noCertificateValidation]
))

// Create and start the connection
let connection = try QuicConnection(registration: registration)
try await connection.start(
    configuration: configuration,
    serverName: "localhost",
    serverPort: 4567
)

// Optional: use round-robin scheduling across streams of the same priority
try connection.setStreamSchedulingScheme(.roundRobin)

// Open a stream and send data
do {
    let stream = try connection.openStream()
    try await stream.start()
    try stream.setPriority(0x9000) // 0xFFFF is highest priority

    let message = "Hello, QUIC!"
    try await stream.send(Data(message.utf8), flags: .fin)

    // Receive the response
    for try await data in stream.receive {
        print("Received: \(String(data: data, encoding: .utf8) ?? "?")")
    }

    await stream.shutdown(flags: .graceful)
}

// Clean up
await connection.shutdown()
```

Release locally opened streams before assuming transport resources are fully closed. `await connection.shutdown()` waits for the transport shutdown event, while `ConnectionClose` still runs from `deinit`.

## Create a Server Listener

Here's how to set up a QUIC server:

```swift
// Create registration
let registration = try QuicRegistration(config: .init(
    appName: "MyQuicServer",
    executionProfile: .lowLatency
))

// Configure settings
var settings = QuicSettings()
settings.peerBidiStreamCount = 100
settings.idleTimeoutMs = 30000

let configuration = try QuicConfiguration(
    registration: registration,
    alpnBuffers: ["my-protocol"],
    settings: settings
)

// Load server certificate
try configuration.loadCredential(.init(
    type: .certificateFile(certPath: "server.crt", keyPath: "server.key"),
    flags: []
))

// Create listener
let listener = try QuicListener(registration: registration)

// Handle new connections
listener.onNewConnection { listener, info in
    print("New connection from \(info.remoteAddress)")

    // Accept the connection and attach a stream handler. The leading
    // `_` in the closure discards the `isolated (any Actor)?` parameter
    // — use a named parameter if you need to hop into a specific actor.
    let connection = try info.accept(configuration: configuration) { _, conn, stream, flags in
        do {
            for try await data in stream.receive {
                print("Received: \(String(data: data, encoding: .utf8) ?? "?")")
                try await stream.send(data) // Echo back
            }
            await stream.shutdown(flags: .graceful)
        } catch {
            print("Stream error: \(error)")
        }
    }

    return connection
}

// Start listening
try listener.start(
    alpnBuffers: ["my-protocol"],
    localAddress: QuicAddress(port: 4567)
)

print("Server listening on port 4567")
```

## Stream Scheduling and Priority

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

## Next Steps

- Learn about ``QuicSettings`` to tune connection parameters
- Explore ``QuicConnectionEvent`` and ``QuicStreamEvent`` for detailed event handling
- See ``QuicCredentialConfig`` for certificate configuration options
