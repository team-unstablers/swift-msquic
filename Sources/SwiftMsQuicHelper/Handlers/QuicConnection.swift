//
//  QuicConnection.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic
import os

/// A QUIC connection that manages communication with a remote peer.
///
/// `QuicConnection` represents a single QUIC connection and provides methods for
/// connecting to servers, managing streams, and handling connection lifecycle events.
///
/// ## Creating a Client Connection
///
/// To connect to a QUIC server:
///
/// ```swift
/// let connection = try QuicConnection(registration: registration)
/// try await connection.start(
///     configuration: configuration,
///     serverName: "example.com",
///     serverPort: 443
/// )
/// ```
///
/// ## Handling Server-Side Connections
///
/// When accepting connections from a ``QuicListener``, use the handle-based initializer:
///
/// ```swift
/// listener.onNewConnection { listener, info in
///     let connection = try QuicConnection(
///         handle: info.connection,
///         configuration: configuration
///     ) { conn, stream, flags in
///         // Handle incoming streams
///     }
///     return connection
/// }
/// ```
///
/// ## Topics
///
/// ### Creating Connections
///
/// - ``init(registration:)``
/// - ``init(handle:configuration:streamHandler:)``
///
/// ### Managing Connection Lifecycle
///
/// - ``start(configuration:serverName:serverPort:)``
/// - ``shutdown(errorCode:)``
/// - ``state``
/// - ``setLocalAddress(_:)``
/// - ``getLocalAddress()``
/// - ``setRemoteAddress(_:)``
/// - ``getRemoteAddress()``
///
/// ### Session Resumption
///
/// - ``setResumptionTicket(_:)``
/// - ``sendResumptionTicket(flags:resumptionData:)``
///
/// ### Working with Streams
///
/// - ``openStream(flags:)``
/// - ``onPeerStreamStarted(_:)``
/// - ``setStreamSchedulingScheme(_:)``
/// - ``getStreamSchedulingScheme()``
///
/// ### Working with Datagrams
///
/// - ``sendDatagram(_:flags:)``
///
/// ### Event Handling
///
/// - ``onEvent(_:)``
/// - ``State``
/// - ``StreamHandler``
/// - ``EventHandler``
public final class QuicConnection: QuicObject, @unchecked Sendable {
    /// The current state of the connection.
    public enum State: Sendable {
        /// Connection has been created but not started.
        case idle
        /// Connection is in the process of connecting to the peer.
        case connecting
        /// Connection is established and ready for data transfer.
        case connected
        /// Connection is shutting down.
        case shuttingDown
        /// Connection has been closed.
        case closed
    }

    /// Stream scheduling behavior used by MsQuic for this connection.
    public enum StreamSchedulingScheme: UInt32, Sendable {
        /// Sends stream data in first-in, first-out order (default).
        case fifo = 0

        /// Sends stream data evenly across streams of the same priority.
        case roundRobin = 1
    }

    private struct InternalState: @unchecked Sendable {
        var connectionState: State = .idle
        var connectContinuation: CheckedContinuation<Void, Error>?
        var shutdownContinuation: CheckedContinuation<Void, Never>?
        var peerStreamHandler: StreamHandler?
        var eventHandler: EventHandler?
        var certificateValidationHandler: CertificateValidationHandler?
        var datagramSendContexts: Set<UInt> = []
    }
    
    private let internalState = OSAllocatedUnfairLock(initialState: InternalState())
    
    /// The current state of the connection.
    public var state: State {
        internalState.withLock { $0.connectionState }
    }

    /// The registration this connection belongs to, if any.
    public let registration: QuicRegistration?

    /// A handler for processing incoming streams initiated by the peer.
    ///
    /// - Parameters:
    ///   - connection: The connection that received the stream.
    ///   - stream: The new stream initiated by the peer.
    ///   - flags: Open flags describing the peer stream direction/properties.
    public typealias StreamHandler = @Sendable (QuicConnection, QuicStream, QuicStreamOpenFlags) async -> Void

    /// A handler for processing connection events.
    ///
    /// - Parameters:
    ///   - connection: The connection that received the event.
    ///   - event: The event that occurred.
    /// - Returns: A status indicating how the event was handled.
    public typealias EventHandler = @Sendable (QuicConnection, QuicConnectionEvent) -> QuicStatus

    /// A handler for validating the peer's certificate.
    ///
    /// This handler is called when the peer's certificate is received and
    /// ``QuicCredentialFlags/indicateCertificateReceived`` is set.
    ///
    /// When ``QuicCredentialFlags/deferCertificateValidation`` is also set,
    /// the return value determines whether the connection should proceed:
    /// - Return ``QuicStatus/success`` to accept the certificate and continue the handshake.
    /// - Return a failure status (e.g., ``QuicStatus/badCertificate``) to reject the certificate.
    ///
    /// - Parameters:
    ///   - connection: The connection that received the certificate.
    ///   - certificate: Platform-specific peer certificate handle.
    ///   - chain: Platform-specific certificate chain handle.
    ///   - deferredErrorFlags: Bit flags indicating validation errors (Schannel only).
    ///   - deferredStatus: The validation error status from the TLS layer.
    /// - Returns: A status indicating whether to accept or reject the certificate.
    public typealias CertificateValidationHandler = @Sendable (
        _ connection: QuicConnection,
        _ certificate: QuicCertificate,
        _ chain: [QuicCertificate],
        _ deferredErrorFlags: QuicCertificateValidationFlags,
        _ deferredStatus: QuicStatus
    ) -> QuicStatus

    private class DatagramSendContext {
        let continuation: CheckedContinuation<Void, Error>
        let buffer: UnsafeMutableRawBufferPointer
        let quicBuffer: UnsafeMutablePointer<QUIC_BUFFER>

        init(_ continuation: CheckedContinuation<Void, Error>, data: Data) {
            self.continuation = continuation
            self.buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: data.count, alignment: 1)
            if data.count > 0 {
                data.copyBytes(to: self.buffer)
            }

            self.quicBuffer = UnsafeMutablePointer<QUIC_BUFFER>.allocate(capacity: 1)
            let bytePtr = data.count > 0 ? self.buffer.bindMemory(to: UInt8.self).baseAddress : nil
            self.quicBuffer.initialize(to: QUIC_BUFFER(Length: UInt32(data.count), Buffer: bytePtr))
        }

        deinit {
            quicBuffer.deinitialize(count: 1)
            quicBuffer.deallocate()
            buffer.deallocate()
        }
    }

    /// Creates a new client-side connection.
    ///
    /// Use this initializer when creating a connection to connect to a remote server.
    /// After creation, call ``start(configuration:serverName:serverPort:)`` to initiate the connection.
    ///
    /// - Parameter registration: The registration to associate with this connection.
    /// - Throws: ``QuicError/invalidState`` if the registration handle is invalid.
    public init(registration: QuicRegistration) throws {
        self.registration = registration
        super.init()
        
        guard let regHandle = registration.handle else {
            throw QuicError.invalidState
        }
        
        var handle: HQUIC? = nil
        let status = QuicStatus(
            api.ConnectionOpen(
                regHandle,
                quicConnectionCallback,
                self.asCInteropHandle,
                &handle
            )
        )
        try status.throwIfFailed()
        self.handle = handle
        retainSelfForCallback()
    }
    
    /// Creates a connection from an existing MsQuic handle.
    ///
    /// Use this initializer when accepting a connection from a ``QuicListener``.
    /// The connection is automatically configured and ready for use.
    ///
    /// - Parameters:
    ///   - handle: The raw MsQuic connection handle from ``QuicListenerEvent/NewConnectionInfo``.
    ///   - configuration: The configuration to apply to this connection.
    ///   - streamHandler: An optional handler for streams initiated by the peer, including open flags.
    /// - Throws: ``QuicError/invalidState`` if the configuration handle is invalid.
    public init(handle: HQUIC, configuration: QuicConfiguration, streamHandler: StreamHandler? = nil) throws {
        self.registration = configuration.registration
        super.init(handle: handle)
        retainSelfForCallback()
        
        internalState.withLock {
            $0.peerStreamHandler = streamHandler
        }
        
        typealias ConnectionCallback = @convention(c) (HQUIC?, UnsafeMutableRawPointer?, UnsafeMutablePointer<QUIC_CONNECTION_EVENT>?) -> QuicStatusRawValue
        let callback = quicConnectionCallback as ConnectionCallback
        let callbackPtr = unsafeBitCast(callback, to: UnsafeMutableRawPointer.self)
        
        api.SetCallbackHandler(handle, callbackPtr, self.asCInteropHandle)
        
        guard let configHandle = configuration.handle else {
            throw QuicError.invalidState
        }
        
        let status = QuicStatus(api.ConnectionSetConfiguration(handle, configHandle))
        try status.throwIfFailed()
        
        internalState.withLock { $0.connectionState = .connected }
    }
    
    /// Starts the connection to a remote server.
    ///
    /// This method initiates the QUIC handshake with the specified server.
    /// The method returns when the connection is established or throws if the connection fails.
    ///
    /// - Parameters:
    ///   - configuration: The configuration containing TLS and QUIC settings.
    ///   - serverName: The hostname or IP address of the server.
    ///   - serverPort: The port number to connect to.
    /// - Throws: ``QuicError`` if the connection fails (e.g., timeout, handshake failure).
    public func start(
        configuration: QuicConfiguration,
        serverName: String,
        serverPort: UInt16
    ) async throws {
        guard let handle = handle else { throw QuicError.invalidState }
        
        let currentState = internalState.withLock { $0.connectionState }
        guard currentState == .idle else { throw QuicError.invalidState }
        
        guard let configHandle = configuration.handle else {
            throw QuicError.invalidParameter
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            internalState.withLock {
                $0.connectContinuation = continuation
                $0.connectionState = .connecting
            }
            
            let status = serverName.withCString { serverNamePtr in
                QuicStatus(
                    api.ConnectionStart(
                        handle,
                        configHandle,
                        QUIC_ADDRESS_FAMILY(QUIC_ADDRESS_FAMILY_UNSPEC),
                        serverNamePtr,
                        serverPort
                    )
                )
            }
            
            if status.failed {
                internalState.withLock {
                    $0.connectContinuation = nil
                    $0.connectionState = .closed
                }
                releaseSelfFromCallback()
                continuation.resume(throwing: QuicError(status: status))
            }
        }
    }
    
    /// Gracefully shuts down the connection.
    ///
    /// This method initiates a graceful shutdown of the connection. All active streams
    /// will be closed, and the connection will be terminated after the shutdown completes.
    ///
    /// - Parameter errorCode: An optional application-defined error code to send to the peer.
    public func shutdown(errorCode: UInt64 = 0) async {
        guard let handle = handle else { return }
        
        let shouldReturn = internalState.withLock { state -> Bool in
            if state.connectionState == .closed { return true }
            state.connectionState = .shuttingDown
            return false
        }
        if shouldReturn { return }
        
        await withCheckedContinuation { continuation in
            internalState.withLock {
                $0.shutdownContinuation = continuation
            }
            
            api.ConnectionShutdown(
                handle,
                QUIC_CONNECTION_SHUTDOWN_FLAG_NONE,
                errorCode
            )
        }
    }

    /// Opens a new stream on this connection.
    ///
    /// Creates a locally-initiated stream. After creation, call ``QuicStream/start(flags:)``
    /// to begin using the stream.
    ///
    /// - Parameter flags: Flags controlling stream behavior (e.g., unidirectional).
    /// - Returns: A new stream ready to be started.
    /// - Throws: ``QuicError`` if the stream cannot be created.
    public func openStream(flags: QuicStreamOpenFlags = .none) throws -> QuicStream {
        return try QuicStream(connection: self, flags: flags)
    }

    /// Sends a connection-level datagram.
    ///
    /// This method queues unreliable data on the connection (not on a stream).
    /// Delivery to the peer is not guaranteed.
    ///
    /// - Parameters:
    ///   - data: The datagram payload.
    ///   - flags: Flags controlling datagram send behavior.
    /// - Throws: ``QuicError`` if the send fails or the datagram is canceled before it is sent.
    public func sendDatagram(_ data: Data, flags: QuicSendFlags = .none) async throws {
        guard let handle = handle else { throw QuicError.invalidState }

        return try await withCheckedThrowingContinuation { continuation in
            let context = DatagramSendContext(continuation, data: data)
            let contextPtr = Unmanaged.passRetained(context).toOpaque()

            let contextToken = UInt(bitPattern: contextPtr)
            _ = internalState.withLock { $0.datagramSendContexts.insert(contextToken) }

            let status = QuicStatus(
                api.DatagramSend(
                    handle,
                    context.quicBuffer,
                    1,
                    QUIC_SEND_FLAGS(flags.rawValue),
                    contextPtr
                )
            )

            if status.failed {
                let sendContext: DatagramSendContext? = internalState.withLock { state in
                    guard state.datagramSendContexts.remove(contextToken) != nil else {
                        return nil
                    }
                    guard let rawPtr = UnsafeMutableRawPointer(bitPattern: contextToken) else {
                        return nil
                    }
                    return Unmanaged<DatagramSendContext>.fromOpaque(rawPtr).takeRetainedValue()
                }
                sendContext?.continuation.resume(throwing: QuicError(status: status))
            }
        }
    }

    /// Sets a client-side resumption ticket to attempt session resumption on the next connect.
    ///
    /// Use this before ``start(configuration:serverName:serverPort:)`` with a ticket previously
    /// received via ``QuicConnectionEvent/resumptionTicketReceived(ticket:)``.
    ///
    /// - Parameter ticket: The raw ticket bytes persisted by the client.
    /// - Throws: ``QuicError`` if the connection is invalid or MsQuic rejects the ticket.
    public func setResumptionTicket(_ ticket: Data) throws {
        guard let handle = handle else { throw QuicError.invalidState }

        guard ticket.count <= Int(UInt32.max) else {
            throw QuicError.invalidParameter
        }

        let status = ticket.withUnsafeBytes { rawBuffer -> QuicStatus in
            let ticketBytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress
            return QuicStatus(
                api.SetParam(
                    handle,
                    UInt32(QUIC_PARAM_CONN_RESUMPTION_TICKET),
                    UInt32(ticket.count),
                    UnsafeMutableRawPointer(mutating: ticketBytes)
                )
            )
        }
        try status.throwIfFailed()
    }

    /// Sends a server-side resumption ticket to the connected client.
    ///
    /// Optionally include application-defined resumption data (up to
    /// `QUIC_MAX_RESUMPTION_APP_DATA_LENGTH` bytes), which is surfaced to the server later
    /// via ``QuicConnectionEvent/resumed(resumptionState:)``.
    ///
    /// - Parameters:
    ///   - flags: Ticket send flags controlling ticket lifecycle behavior.
    ///   - resumptionData: Optional app-specific data to embed in the ticket.
    /// - Throws: ``QuicError`` if the connection is invalid, parameters are out of range, or MsQuic fails.
    public func sendResumptionTicket(
        flags: QuicSendResumptionFlags = .none,
        resumptionData: Data? = nil
    ) throws {
        guard let handle = handle else {
            throw QuicError.invalidState
        }

        let data = resumptionData ?? Data()
        guard data.count <= Int(QUIC_MAX_RESUMPTION_APP_DATA_LENGTH) else {
            throw QuicError.invalidParameter
        }
        guard data.count <= Int(UInt16.max) else {
            throw QuicError.invalidParameter
        }

        let status = data.withUnsafeBytes { rawBuffer -> QuicStatus in
            let ticketBytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress
            return QuicStatus(
                api.ConnectionSendResumptionTicket(
                    handle,
                    QUIC_SEND_RESUMPTION_FLAGS(flags.rawValue),
                    UInt16(data.count),
                    ticketBytes
                )
            )
        }
        try status.throwIfFailed()
    }

    /// Sets the stream scheduling scheme for this connection.
    ///
    /// - Parameter scheme: The scheduling behavior to apply.
    /// - Throws: ``QuicError`` if the connection is invalid or MsQuic rejects the parameter.
    public func setStreamSchedulingScheme(_ scheme: StreamSchedulingScheme) throws {
        guard let handle = handle else { throw QuicError.invalidState }

        var rawScheme = scheme.rawValue
        let status = QuicStatus(
            api.SetParam(
                handle,
                UInt32(QUIC_PARAM_CONN_STREAM_SCHEDULING_SCHEME),
                UInt32(MemoryLayout.size(ofValue: rawScheme)),
                &rawScheme
            )
        )
        try status.throwIfFailed()
    }

    /// Gets the current stream scheduling scheme for this connection.
    ///
    /// - Returns: The current scheduling behavior.
    /// - Throws: ``QuicError`` if the connection is invalid, MsQuic fails, or an unexpected value is returned.
    public func getStreamSchedulingScheme() throws -> StreamSchedulingScheme {
        guard let handle = handle else { throw QuicError.invalidState }

        var rawScheme: UInt32 = 0
        var bufferLength = UInt32(MemoryLayout.size(ofValue: rawScheme))

        let status = QuicStatus(
            api.GetParam(
                handle,
                UInt32(QUIC_PARAM_CONN_STREAM_SCHEDULING_SCHEME),
                &bufferLength,
                &rawScheme
            )
        )
        try status.throwIfFailed()

        guard
            bufferLength == UInt32(MemoryLayout.size(ofValue: rawScheme)),
            let scheme = StreamSchedulingScheme(rawValue: rawScheme)
        else {
            throw QuicError.invalidState
        }

        return scheme
    }

    /// Sets the local network address for this connection.
    ///
    /// This maps to `QUIC_PARAM_CONN_LOCAL_ADDRESS`.
    ///
    /// - Parameter address: The local address to bind.
    /// - Throws: ``QuicError`` if the connection is invalid or MsQuic rejects the parameter.
    public func setLocalAddress(_ address: QuicAddress) throws {
        guard let handle = handle else { throw QuicError.invalidState }

        var rawAddress = address.raw
        let status = QuicStatus(
            api.SetParam(
                handle,
                UInt32(QUIC_PARAM_CONN_LOCAL_ADDRESS),
                UInt32(MemoryLayout.size(ofValue: rawAddress)),
                &rawAddress
            )
        )
        try status.throwIfFailed()
    }

    /// Gets the current local network address for this connection.
    ///
    /// This maps to `QUIC_PARAM_CONN_LOCAL_ADDRESS`.
    ///
    /// - Returns: The local address currently associated with the connection.
    /// - Throws: ``QuicError`` if the connection is invalid, MsQuic fails, or an unexpected value is returned.
    public func getLocalAddress() throws -> QuicAddress {
        guard let handle = handle else { throw QuicError.invalidState }

        var rawAddress = QUIC_ADDR()
        var bufferLength = UInt32(MemoryLayout.size(ofValue: rawAddress))

        let status = QuicStatus(
            api.GetParam(
                handle,
                UInt32(QUIC_PARAM_CONN_LOCAL_ADDRESS),
                &bufferLength,
                &rawAddress
            )
        )
        try status.throwIfFailed()

        guard bufferLength == UInt32(MemoryLayout.size(ofValue: rawAddress)) else {
            throw QuicError.invalidState
        }

        return QuicAddress(rawAddress)
    }

    /// Sets the remote network address for this connection.
    ///
    /// This maps to `QUIC_PARAM_CONN_REMOTE_ADDRESS`.
    ///
    /// - Parameter address: The remote peer address to apply.
    /// - Throws: ``QuicError`` if the connection is invalid or MsQuic rejects the parameter.
    public func setRemoteAddress(_ address: QuicAddress) throws {
        guard let handle = handle else { throw QuicError.invalidState }

        var rawAddress = address.raw
        let status = QuicStatus(
            api.SetParam(
                handle,
                UInt32(QUIC_PARAM_CONN_REMOTE_ADDRESS),
                UInt32(MemoryLayout.size(ofValue: rawAddress)),
                &rawAddress
            )
        )
        try status.throwIfFailed()
    }

    /// Gets the current remote network address for this connection.
    ///
    /// This maps to `QUIC_PARAM_CONN_REMOTE_ADDRESS`.
    ///
    /// - Returns: The remote address currently associated with the connection.
    /// - Throws: ``QuicError`` if the connection is invalid, MsQuic fails, or an unexpected value is returned.
    public func getRemoteAddress() throws -> QuicAddress {
        guard let handle = handle else { throw QuicError.invalidState }

        var rawAddress = QUIC_ADDR()
        var bufferLength = UInt32(MemoryLayout.size(ofValue: rawAddress))

        let status = QuicStatus(
            api.GetParam(
                handle,
                UInt32(QUIC_PARAM_CONN_REMOTE_ADDRESS),
                &bufferLength,
                &rawAddress
            )
        )
        try status.throwIfFailed()

        guard bufferLength == UInt32(MemoryLayout.size(ofValue: rawAddress)) else {
            throw QuicError.invalidState
        }

        return QuicAddress(rawAddress)
    }

    /// Sets a handler for streams initiated by the peer.
    ///
    /// This handler is called whenever the remote peer opens a new stream on this connection.
    ///
    /// - Parameter handler: A closure that processes the new stream and its open flags asynchronously.
    public func onPeerStreamStarted(_ handler: @escaping StreamHandler) {
        internalState.withLock {
            $0.peerStreamHandler = handler
        }
    }

    /// Sets a handler for connection events.
    ///
    /// Use this to receive low-level connection events. This is useful for monitoring
    /// connection state changes or handling events not covered by the high-level API.
    ///
    /// - Parameter handler: A closure that processes connection events.
    public func onEvent(_ handler: @escaping EventHandler) {
        internalState.withLock {
            $0.eventHandler = handler
        }
    }

    /// Sets a handler for validating the peer's certificate.
    ///
    /// This handler is invoked when the peer's certificate is received during the TLS handshake.
    /// To receive this event, you must set ``QuicCredentialFlags/indicateCertificateReceived``
    /// when loading credentials.
    ///
    /// ## Basic Usage (Certificate Inspection)
    ///
    /// ```swift
    /// connection.onPeerCertificateReceived { conn, cert, chain, errorFlags, status in
    ///     // Log certificate information
    ///     print("Received peer certificate")
    ///     return .success  // Accept the certificate
    /// }
    /// ```
    ///
    /// ## Custom Validation (with deferCertificateValidation)
    ///
    /// When ``QuicCredentialFlags/deferCertificateValidation`` is set, you can perform
    /// custom validation and decide whether to accept or reject the certificate:
    ///
    /// ```swift
    /// // When loading credentials:
    /// try config.loadCredential(.init(
    ///     type: .none,
    ///     flags: [.client, .indicateCertificateReceived, .deferCertificateValidation]
    /// ))
    ///
    /// // Handle certificate validation:
    /// connection.onPeerCertificateReceived { conn, cert, chain, errorFlags, status in
    ///     // Perform custom validation (e.g., certificate pinning)
    ///     if isValidPinnedCertificate(cert) {
    ///         return .success
    ///     } else {
    ///         return .badCertificate
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter handler: A closure that validates the certificate and returns a status.
    public func onPeerCertificateReceived(_ handler: @escaping CertificateValidationHandler) {
        internalState.withLock {
            $0.certificateValidationHandler = handler
        }
    }
    
    internal func handleEvent(_ event: QUIC_CONNECTION_EVENT) -> QuicStatus {
        let swiftEvent = QuicEventConverter.convert(event)
        
        let eventHandler = internalState.withLock { $0.eventHandler }
        if let handler = eventHandler {
            let status = handler(self, swiftEvent)
            if status != .success {
                return status
            }
        }
        
        switch swiftEvent {
        case .connected:
            let continuation = internalState.withLock { state -> CheckedContinuation<Void, Error>? in
                state.connectionState = .connected
                let c = state.connectContinuation
                state.connectContinuation = nil
                return c
            }
            continuation?.resume()
            
        case .shutdownInitiatedByTransport(let status, _):
            let continuation = internalState.withLock { state -> CheckedContinuation<Void, Error>? in
                let c = state.connectContinuation
                state.connectContinuation = nil
                return c
            }
            continuation?.resume(throwing: QuicError(status: status))
            
        case .shutdownInitiatedByPeer:
            let continuation = internalState.withLock { state -> CheckedContinuation<Void, Error>? in
                let c = state.connectContinuation
                state.connectContinuation = nil
                return c
            }
            continuation?.resume(throwing: QuicError.aborted)
            
        case .shutdownComplete:
            let (shutdownContinuation, connectContinuation, datagramSendContexts) = internalState.withLock {
                state -> (
                    CheckedContinuation<Void, Never>?,
                    CheckedContinuation<Void, Error>?,
                    [UInt]
                ) in
                state.connectionState = .closed
                let sc = state.shutdownContinuation
                state.shutdownContinuation = nil

                let cc = state.connectContinuation
                state.connectContinuation = nil

                let contexts = Array(state.datagramSendContexts)
                state.datagramSendContexts.removeAll()

                return (sc, cc, contexts)
            }
            for contextToken in datagramSendContexts {
                guard let contextPtr = UnsafeMutableRawPointer(bitPattern: contextToken) else {
                    continue
                }
                let sendContext = Unmanaged<DatagramSendContext>.fromOpaque(contextPtr).takeRetainedValue()
                sendContext.continuation.resume(throwing: QuicError.aborted)
            }
            // Release self-ref synchronously before resuming continuations.
            // The caller still holds a strong reference, so deinit won't fire on the callback thread.
            self.releaseSelfFromCallback()
            shutdownContinuation?.resume()
            connectContinuation?.resume(throwing: QuicError.aborted)

        case .datagramSendStateChanged(let state, let context):
            guard let context else {
                break
            }
            let contextToken = UInt(bitPattern: context)

            switch state {
            case .sent, .lostDiscarded, .acknowledged, .acknowledgedSpurious:
                let sendContext: DatagramSendContext? = internalState.withLock { state in
                    guard state.datagramSendContexts.remove(contextToken) != nil else {
                        return nil
                    }
                    guard let rawPtr = UnsafeMutableRawPointer(bitPattern: contextToken) else {
                        return nil
                    }
                    return Unmanaged<DatagramSendContext>.fromOpaque(rawPtr).takeRetainedValue()
                }
                sendContext?.continuation.resume()

            case .canceled, .unknown:
                let sendContext: DatagramSendContext? = internalState.withLock { state in
                    guard state.datagramSendContexts.remove(contextToken) != nil else {
                        return nil
                    }
                    guard let rawPtr = UnsafeMutableRawPointer(bitPattern: contextToken) else {
                        return nil
                    }
                    return Unmanaged<DatagramSendContext>.fromOpaque(rawPtr).takeRetainedValue()
                }
                sendContext?.continuation.resume(throwing: QuicError.aborted)

            case .lostSuspect:
                break
            }
            
        case .peerStreamStarted(let streamHandle, let flags):
            let handler = internalState.withLock { $0.peerStreamHandler }
            if let handler {
                let stream = QuicStream(handle: streamHandle)
                Task {
                    await handler(self, stream, flags)
                }
            }

        case .peerCertificateReceived(let certificate, let chain, let errorFlags, let status):
            let handler = internalState.withLock { $0.certificateValidationHandler }
            if let handler {
                return handler(self, certificate, chain, errorFlags, status)
            }
            return .success

        default:
            break
        }

        return .success
    }
    
    deinit {
        let datagramSendContexts = internalState.withLock { state -> [UInt] in
            let contexts = Array(state.datagramSendContexts)
            state.datagramSendContexts.removeAll()
            return contexts
        }
        for contextToken in datagramSendContexts {
            guard let contextPtr = UnsafeMutableRawPointer(bitPattern: contextToken) else {
                continue
            }
            let sendContext = Unmanaged<DatagramSendContext>.fromOpaque(contextPtr).takeRetainedValue()
            sendContext.continuation.resume(throwing: QuicError.aborted)
        }

        if let handle = handle {
            api.ConnectionClose(handle)
        }
    }
}
