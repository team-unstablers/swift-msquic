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
///     ) { conn, stream in
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
///
/// ### Working with Streams
///
/// - ``openStream(flags:)``
/// - ``onPeerStreamStarted(_:)``
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
    
    private struct InternalState: @unchecked Sendable {
        var connectionState: State = .idle
        var connectContinuation: CheckedContinuation<Void, Error>?
        var shutdownContinuation: CheckedContinuation<Void, Never>?
        var shutdownThrowingContinuation: CheckedContinuation<Void, Error>?
        var peerStreamHandler: StreamHandler?
        var eventHandler: EventHandler?
        var certificateValidationHandler: CertificateValidationHandler?
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
    public typealias StreamHandler = @Sendable (QuicConnection, QuicStream) async -> Void

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
    ///   - streamHandler: An optional handler for streams initiated by the peer.
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

    /// Gracefully shuts down the connection with a timeout.
    ///
    /// This method waits for the shutdown to complete up to the specified timeout.
    /// If the timeout expires and `force` is `true`, the connection is force-closed.
    ///
    /// - Parameters:
    ///   - errorCode: An optional application-defined error code to send to the peer.
    ///   - timeoutMs: Maximum time to wait for shutdown completion, in milliseconds.
    ///   - force: If `true`, force-close the connection when the timeout expires.
    /// - Throws: ``QuicError/connectionTimeout`` if the timeout expires before shutdown completes.
    public func shutdown(errorCode: UInt64 = 0, timeoutMs: UInt64, force: Bool = true) async throws {
        guard let handle = handle else { return }

        let shouldReturn = internalState.withLock { state -> Bool in
            if state.connectionState == .closed { return true }
            state.connectionState = .shuttingDown
            return false
        }
        if shouldReturn { return }

        try await withCheckedThrowingContinuation { continuation in
            internalState.withLock {
                $0.shutdownThrowingContinuation = continuation
            }

            api.ConnectionShutdown(
                handle,
                QUIC_CONNECTION_SHUTDOWN_FLAG_NONE,
                errorCode
            )

            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                } catch {
                    return
                }

                let continuationToResume = self.internalState.withLock { state -> CheckedContinuation<Void, Error>? in
                    let continuation = state.shutdownThrowingContinuation
                    if continuation != nil {
                        state.shutdownThrowingContinuation = nil
                    }
                    return continuation
                }

                guard let continuationToResume else { return }
                continuationToResume.resume(throwing: QuicError.connectionTimeout)

                guard force, let handle = self.handle else { return }
                self.api.ConnectionClose(handle)
            }
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

    /// Sets a handler for streams initiated by the peer.
    ///
    /// This handler is called whenever the remote peer opens a new stream on this connection.
    ///
    /// - Parameter handler: A closure that processes the new stream asynchronously.
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
            let (shutdownContinuation, shutdownThrowingContinuation, connectContinuation) = internalState.withLock { state -> (CheckedContinuation<Void, Never>?, CheckedContinuation<Void, Error>?, CheckedContinuation<Void, Error>?) in
                state.connectionState = .closed
                let sc = state.shutdownContinuation
                state.shutdownContinuation = nil
                let stc = state.shutdownThrowingContinuation
                state.shutdownThrowingContinuation = nil

                let cc = state.connectContinuation
                state.connectContinuation = nil

                return (sc, stc, cc)
            }
            shutdownContinuation?.resume()
            shutdownThrowingContinuation?.resume()
            connectContinuation?.resume(throwing: QuicError.aborted)
            
            Task {
                self.releaseSelfFromCallback()
            }
            
        case .peerStreamStarted(let streamHandle, _):
            let handler = internalState.withLock { $0.peerStreamHandler }
            if let handler {
                let stream = QuicStream(handle: streamHandle)
                Task {
                    await handler(self, stream)
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
        if let handle = handle {
            api.ConnectionClose(handle)
        }
    }
}
