//
//  QuicStream.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic
import os

/// A QUIC stream for bidirectional or unidirectional data transfer.
///
/// `QuicStream` represents a single stream within a QUIC connection. Streams provide
/// ordered, reliable data transfer and can be either bidirectional or unidirectional.
///
/// ## Sending Data
///
/// Use ``send(_:flags:)`` to send data on the stream:
///
/// ```swift
/// let stream = try connection.openStream()
/// try await stream.start()
///
/// try await stream.send(Data("Hello".utf8))
/// try await stream.send(Data("World".utf8), flags: .fin) // Last message
/// ```
///
/// ## Receiving Data
///
/// Use the ``receive`` property to iterate over incoming data:
///
/// ```swift
/// for try await data in stream.receive {
///     print("Received: \(String(data: data, encoding: .utf8) ?? "?")")
/// }
/// ```
///
/// ## Topics
///
/// ### Creating Streams
///
/// Streams are created through ``QuicConnection/openStream(flags:)`` or received
/// via ``QuicConnection/onPeerStreamStarted(_:)``.
///
/// ### Managing Stream Lifecycle
///
/// - ``start(flags:)``
/// - ``shutdown(errorCode:)``
/// - ``shutdownSend(errorCode:)``
/// - ``shutdownReceive(errorCode:)``
/// - ``state``
///
/// ### Data Transfer
///
/// - ``send(_:flags:)``
/// - ``receive``
public final class QuicStream: QuicObject, @unchecked Sendable {

    /// The current state of the stream.
    public enum State: Sendable {
        /// Stream has been created but not started.
        case idle
        /// Stream is in the process of starting.
        case starting
        /// Stream is open and ready for data transfer.
        case open
        /// Stream is shutting down.
        case shuttingDown
        /// Stream has been closed.
        case closed
    }
    
    private struct InternalState: Sendable {
        var streamState: State = .idle
        var startContinuation: CheckedContinuation<Void, Error>?
        var shutdownContinuation: CheckedContinuation<Void, Never>?
        var receiveContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    }
    private let internalState = OSAllocatedUnfairLock(initialState: InternalState())
    
    /// The current state of the stream.
    public var state: State {
        internalState.withLock { $0.streamState }
    }

    /// The connection this stream belongs to, if known.
    ///
    /// This is `nil` for streams received from a peer, as they are created
    /// with just the handle.
    public let connection: QuicConnection?
    
    private class SendContext {
        let continuation: CheckedContinuation<Void, Error>
        let buffer: UnsafeMutableRawBufferPointer
        let quicBuffer: UnsafeMutablePointer<QUIC_BUFFER>
        
        init(_ c: CheckedContinuation<Void, Error>, data: Data) {
            self.continuation = c
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
    
    private var _receiveStream: AsyncThrowingStream<Data, Error>?

    /// An asynchronous stream of data received from the peer.
    ///
    /// Iterate over this property to receive data sent by the remote peer.
    /// The stream completes when the peer finishes sending or aborts.
    ///
    /// ```swift
    /// for try await data in stream.receive {
    ///     // Process received data
    /// }
    /// ```
    public var receive: AsyncThrowingStream<Data, Error> {
        internalState.withLock { state in
            if let existing = _receiveStream {
                return existing
            }
            // Should not happen if initialized correctly
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            state.receiveContinuation = continuation
            return stream
        }
    }
    
    internal override init(handle: HQUIC) {
        self.connection = nil
        super.init(handle: handle)
        retainSelfForCallback()
        
        typealias StreamCallback = @convention(c) (HQUIC?, UnsafeMutableRawPointer?, UnsafeMutablePointer<QUIC_STREAM_EVENT>?) -> QuicStatusRawValue
        let callback = quicStreamCallback as StreamCallback
        let callbackPtr = unsafeBitCast(callback, to: UnsafeMutableRawPointer.self)
        
        api.SetCallbackHandler(handle, callbackPtr, self.asCInteropHandle)
        
        initReceiveStream()
        
        internalState.withLock { $0.streamState = .open }
    }
    
    internal init(connection: QuicConnection, flags: QuicStreamOpenFlags) throws {
        self.connection = connection
        super.init()
        retainSelfForCallback()
        
        guard let connHandle = connection.handle else {
            releaseSelfFromCallback()
            throw QuicError.invalidState
        }
        
        var handle: HQUIC? = nil
        let status = QuicStatus(
            api.StreamOpen(
                connHandle,
                QUIC_STREAM_OPEN_FLAGS(flags.rawValue),
                quicStreamCallback,
                self.asCInteropHandle,
                &handle
            )
        )
        do {
            try status.throwIfFailed()
        } catch {
            releaseSelfFromCallback()
            throw error
        }
        self.handle = handle
        
        initReceiveStream()
    }
    
    private func initReceiveStream() {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self._receiveStream = stream
        internalState.withLock { $0.receiveContinuation = continuation }
    }
    
    /// Starts the stream.
    ///
    /// Call this method after creating a stream with ``QuicConnection/openStream(flags:)``
    /// to begin using the stream.
    ///
    /// - Parameter flags: Flags controlling stream start behavior.
    /// - Throws: ``QuicError`` if the stream cannot be started.
    public func start(flags: QuicStreamStartFlags = .none) async throws {
        guard let handle = handle else { throw QuicError.invalidState }
        
        return try await withCheckedThrowingContinuation { continuation in
            internalState.withLock {
                $0.startContinuation = continuation
                $0.streamState = .starting
            }
            
            let status = QuicStatus(
                api.StreamStart(
                    handle,
                    QUIC_STREAM_START_FLAGS(flags.rawValue)
                )
            )
            
            if status.failed {
                internalState.withLock {
                    $0.startContinuation = nil
                    $0.streamState = .closed
                }
                releaseSelfFromCallback()
                continuation.resume(throwing: QuicError(status: status))
            }
        }
    }
    
    /// Sends data on the stream.
    ///
    /// This method queues data for sending and returns when the send is complete.
    ///
    /// - Parameters:
    ///   - data: The data to send.
    ///   - flags: Flags controlling send behavior. Use `.fin` to indicate this is the last send.
    /// - Throws: ``QuicError`` if the send fails.
    public func send(_ data: Data, flags: QuicSendFlags = .none) async throws {
        guard let handle = handle else { throw QuicError.invalidState }
        
        return try await withCheckedThrowingContinuation { continuation in
            let context = SendContext(continuation, data: data)
            let contextPtr = Unmanaged.passRetained(context).toOpaque()
            
            let status = QuicStatus(
                api.StreamSend(
                    handle,
                    context.quicBuffer,
                    1,
                    QUIC_SEND_FLAGS(flags.rawValue),
                    contextPtr
                )
            )
            
            if status.failed {
                let _ = Unmanaged<SendContext>.fromOpaque(contextPtr).takeRetainedValue()
                continuation.resume(throwing: QuicError(status: status))
            }
        }
    }
    
    /// Aborts the stream in both directions.
    ///
    /// This immediately terminates the stream, aborting any pending sends and receives.
    ///
    /// - Parameter errorCode: An optional application-defined error code to send to the peer.
    public func shutdown(errorCode: UInt64 = 0) async {
        guard let handle = handle else { return }

        await withCheckedContinuation { continuation in
            internalState.withLock {
                $0.shutdownContinuation = continuation
                $0.streamState = .shuttingDown
            }

            _ = api.StreamShutdown(
                handle,
                QUIC_STREAM_SHUTDOWN_FLAG_ABORT,
                errorCode
            )
        }
    }

    /// Gracefully shuts down the send direction of the stream.
    ///
    /// This signals to the peer that no more data will be sent (FIN).
    /// Any pending sends will be completed before the shutdown takes effect.
    ///
    /// - Parameter errorCode: An optional application-defined error code.
    public func shutdownSend(errorCode: UInt64 = 0) {
        guard let handle = handle else { return }
        _ = api.StreamShutdown(handle, QUIC_STREAM_SHUTDOWN_FLAG_GRACEFUL, errorCode)
    }

    /// Aborts the receive direction of the stream.
    ///
    /// This signals to the peer that no more data will be accepted.
    ///
    /// - Parameter errorCode: An optional application-defined error code to send to the peer.
    public func shutdownReceive(errorCode: UInt64 = 0) {
        guard let handle = handle else { return }
        _ = api.StreamShutdown(handle, QUIC_STREAM_SHUTDOWN_FLAG_ABORT_RECEIVE, errorCode)
    }
    
    internal func handleEvent(_ event: QUIC_STREAM_EVENT) -> QuicStatus {
        let swiftEvent = QuicEventConverter.convert(event)
        
        switch swiftEvent {
        case .startComplete(let status, _, _):
            let continuation = internalState.withLock { state -> CheckedContinuation<Void, Error>? in
                let c = state.startContinuation
                state.startContinuation = nil
                if status.succeeded {
                    state.streamState = .open
                }
                return c
            }
            if status.failed {
                continuation?.resume(throwing: QuicError(status: status))
            } else {
                continuation?.resume()
            }
            
        case .receive(let data, _, _, let totalLength):
            internalState.withLock { $0.receiveContinuation }?.yield(data)
            if let handle = handle {
                api.StreamReceiveComplete(handle, totalLength)
                return .pending
            }
            
        case .sendComplete(let canceled, let context):
            if let context = context {
                let sendContext = Unmanaged<SendContext>.fromOpaque(context).takeRetainedValue()
                if canceled {
                    sendContext.continuation.resume(throwing: QuicError.aborted)
                } else {
                    sendContext.continuation.resume()
                }
            }
            
        case .peerSendShutdown:
            internalState.withLock { $0.receiveContinuation }?.finish()
            
        case .peerSendAborted(_):
            // TODO: Pass error code
            internalState.withLock { $0.receiveContinuation }?.finish(throwing: QuicError.aborted)
            
        case .peerReceiveAborted:
            break
            
        case .shutdownComplete:
            let continuation = internalState.withLock { state -> CheckedContinuation<Void, Never>? in
                state.streamState = .closed
                let c = state.shutdownContinuation
                state.shutdownContinuation = nil
                return c
            }
            continuation?.resume()
            Task {
                self.releaseSelfFromCallback()
            }
            
        default:
            break
        }
        
        return .success
    }
    
    deinit {
        if let handle = handle {
            api.StreamClose(handle)
        }
        internalState.withLock { $0.receiveContinuation }?.finish()
    }
}
