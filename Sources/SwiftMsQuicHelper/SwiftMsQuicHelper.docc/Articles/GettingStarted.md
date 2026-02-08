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
let stream = try connection.openStream()
try await stream.start()
try stream.setPriority(0x9000) // 0xFFFF is highest priority

let message = "Hello, QUIC!"
try await stream.send(Data(message.utf8), flags: .fin)

// Receive the response
for try await data in stream.receive {
    print("Received: \(String(data: data, encoding: .utf8) ?? "?")")
}

// Clean up
await connection.shutdown()
```

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

    let connection = try QuicConnection(
        handle: info.connection,
        configuration: configuration
    ) { conn, stream, flags in
        // Handle incoming streams
        for try await data in stream.receive {
            print("Received: \(String(data: data, encoding: .utf8) ?? "?")")
            try await stream.send(data) // Echo back
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
