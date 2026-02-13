# ``SwiftMsQuicHelper``

A Swift wrapper for Microsoft's MsQuic library, providing modern async/await APIs for QUIC protocol communication.

## Overview

SwiftMsQuicHelper provides a Swift-friendly interface to the MsQuic library, enabling you to build high-performance network applications using the QUIC protocol. The library leverages Swift Concurrency (async/await) for clean and efficient asynchronous code.

### Key Features

- **Modern Swift API**: Uses async/await for all asynchronous operations
- **ARC-based Resource Management**: Automatic cleanup of MsQuic handles via deinit
- **Swift Enums for Events**: Type-safe event handling with associated values
- **OptionSet Flags**: Swift-native flag types for all MsQuic flags
- **Non-buffered Windowed Send**: `sendChunks` provides IDEAL_SEND_BUFFER_SIZE-based multi in-flight stream send

### Supported Platforms

- macOS 13.0+
- iOS 16.0+

## Topics

### Essentials

- ``SwiftMsQuicAPI``
- <doc:GettingStarted>

### Configuration

- ``QuicRegistration``
- ``QuicRegistrationConfig``
- ``QuicConfiguration``
- ``QuicSettings``
- ``QuicCredentialConfig``
- ``QuicCredentialType``
- ``QuicCredentialFlags``
- ``QuicExecutionProfile``

### Networking

- ``QuicListener``
- ``QuicConnection``
- ``QuicStream``

### Events

- ``QuicListenerEvent``
- ``QuicConnectionEvent``
- ``QuicStreamEvent``
- ``QuicDatagramSendState``

### Supporting Types

- ``QuicAddress``
- ``QuicBuffer``
- ``QuicStatus``
- ``QuicError``
- ``QuicObject``

### Flags

- ``QuicStreamOpenFlags``
- ``QuicStreamStartFlags``
- ``QuicReceiveFlags``
- ``QuicSendFlags``
