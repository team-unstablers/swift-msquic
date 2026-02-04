//
//  QuicListener.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic
import os

/// A QUIC listener that accepts incoming connections from clients.
///
/// `QuicListener` listens for incoming QUIC connections on a specified address and port.
/// Use it to build QUIC servers that accept multiple client connections.
///
/// ## Setting Up a Server
///
/// ```swift
/// let listener = try QuicListener(registration: registration)
///
/// listener.onNewConnection { listener, info in
///     print("New connection from \(info.remoteAddress)")
///
///     let connection = try QuicConnection(
///         handle: info.connection,
///         configuration: configuration
///     ) { conn, stream in
///         // Handle incoming streams
///     }
///
///     return connection
/// }
///
/// try listener.start(alpnBuffers: ["my-protocol"], localAddress: QuicAddress(port: 443))
/// ```
///
/// ## Topics
///
/// ### Creating Listeners
///
/// - ``init(registration:)``
///
/// ### Managing Listener Lifecycle
///
/// - ``start(alpnBuffers:localAddress:)``
/// - ``stop()``
///
/// ### Handling Connections
///
/// - ``onNewConnection(_:)``
/// - ``ConnectionHandler``
public final class QuicListener: QuicObject {
    /// The registration this listener belongs to.
    public let registration: QuicRegistration

    /// A handler for processing incoming connections.
    ///
    /// - Parameters:
    ///   - listener: The listener that received the connection.
    ///   - info: Information about the incoming connection.
    /// - Returns: A ``QuicConnection`` to accept the connection, or `nil` to reject it.
    /// - Throws: If the connection should be rejected with an error.
    public typealias ConnectionHandler = @Sendable (QuicListener, QuicListenerEvent.NewConnectionInfo) throws -> QuicConnection?
    
    private struct InternalState: @unchecked Sendable {
        var stopContinuation: CheckedContinuation<Void, Never>?
        var connectionHandler: ConnectionHandler?
    }
    private let internalState = OSAllocatedUnfairLock(initialState: InternalState())

    /// Creates a new listener.
    ///
    /// - Parameter registration: The registration to associate with this listener.
    /// - Throws: ``QuicError/invalidState`` if the registration handle is invalid.
    public init(registration: QuicRegistration) throws {
        self.registration = registration
        super.init()
        
        guard let regHandle = registration.handle else {
            throw QuicError.invalidState
        }
        
        var handle: HQUIC? = nil
        let status = QuicStatus(
            api.ListenerOpen(
                regHandle,
                quicListenerCallback,
                self.asCInteropHandle,
                &handle
            )
        )
        try status.throwIfFailed()
        self.handle = handle
        retainSelfForCallback()
    }
    
    /// Starts the listener to accept incoming connections.
    ///
    /// After calling this method, the listener will begin accepting connections
    /// from clients that connect with one of the specified ALPN protocols.
    ///
    /// - Parameters:
    ///   - alpnBuffers: The list of supported ALPN protocol names.
    ///   - localAddress: The local address and port to listen on. If `nil`, listens on all interfaces.
    /// - Throws: ``QuicError`` if the listener cannot be started.
    public func start(alpnBuffers: [String], localAddress: QuicAddress? = nil) throws {
        guard let handle = handle else { throw QuicError.invalidState }
        
        let alpnQuicBuffers = alpnBuffers.map { QuicBuffer($0) }
        
        try withQuicBufferArray(alpnQuicBuffers) { buffersPtr, bufferCount in
            try localAddress?.withUnsafeAddress { addrPtr in
                let status = QuicStatus(
                    api.ListenerStart(
                        handle,
                        buffersPtr,
                        bufferCount,
                        addrPtr
                    )
                )
                try status.throwIfFailed()
            } ?? {
                let status = QuicStatus(
                    api.ListenerStart(
                        handle,
                        buffersPtr,
                        bufferCount,
                        nil
                    )
                )
                try status.throwIfFailed()
            }()
        }
    }
    
    /// Stops the listener.
    ///
    /// After this method returns, no new connections will be accepted.
    /// Existing connections are not affected.
    public func stop() async {
        guard let handle = handle else { return }

        await withCheckedContinuation { continuation in
            internalState.withLock {
                $0.stopContinuation = continuation
            }

            api.ListenerStop(handle)
        }
    }

    /// Sets a handler for new incoming connections.
    ///
    /// This handler is called when a new client connection is received.
    /// Return a configured ``QuicConnection`` to accept the connection,
    /// or `nil` to reject it.
    ///
    /// - Parameter handler: A closure that decides whether to accept each connection.
    public func onNewConnection(_ handler: @escaping ConnectionHandler) {
        internalState.withLock {
            $0.connectionHandler = handler
        }
    }
    
    internal func handleEvent(_ event: QUIC_LISTENER_EVENT) -> QuicStatus {
        let swiftEvent = QuicEventConverter.convert(event)
        
        switch swiftEvent {
        case .newConnection(let info):
            let handler = internalState.withLock { $0.connectionHandler }
            guard let handler else {
                return .connectionRefused
            }
            do {
                if let _ = try handler(self, info) {
                    // Accepted
                    return .success
                }
                // Rejected
                api.ConnectionClose(info.connection)
                return .connectionRefused
            } catch {
                api.ConnectionClose(info.connection)
                return .connectionRefused
            }
            
        case .stopComplete:
            let continuation = internalState.withLock {
                let c = $0.stopContinuation
                $0.stopContinuation = nil
                return c
            }
            continuation?.resume()
            Task {
                self.releaseSelfFromCallback()
            }
            return .success
            
        default:
            return .success
        }
    }
    
    deinit {
        if let handle = handle {
            api.ListenerClose(handle)
        }
    }
}
