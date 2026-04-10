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
/// - ``state``
///
/// ### Data Transfer
///
/// - ``send(_:flags:)``
/// - ``receive``
/// - ``setPriority(_:)``
/// - ``getPriority()``
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
    
    /// Mutable state protected by the `internalState` lock.
    ///
    /// Marked `@unchecked Sendable` because the struct stores
    /// `CheckedContinuation` and `AsyncThrowingStream.Continuation` values,
    /// whose automatic `Sendable` derivation is not guaranteed under strict
    /// concurrency. All reads and writes MUST go through
    /// `internalState.withLock { ... }`.
    private struct InternalState: @unchecked Sendable {
        var streamState: State = .idle
        var startContinuation: CheckedContinuation<Void, Error>?
        var shutdownContinuation: CheckedContinuation<Void, Never>?
        var receiveContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        var receiveStream: AsyncThrowingStream<Data, Error>?
    }
    private let internalState = OSAllocatedUnfairLock(initialState: InternalState())
    
    /// The current state of the stream.
    public var state: State {
        internalState.withLock { $0.streamState }
    }

    /// The connection this stream belongs to, if known.
    ///
    /// This is `nil` for streams received from a peer, as they are created
    /// with just the handle. For locally opened streams, this is a weak
    /// back-reference, so keep the connection strongly retained elsewhere for
    /// the lifetime of the stream.
    public private(set) weak var connection: QuicConnection?

    private enum ShutdownAction {
        case resumeImmediately
        case call(previousState: State)
    }
    
    private class SendContext {
        let continuation: CheckedContinuation<Void, Error>?
        let buffer: UnsafeMutableRawBufferPointer
        let quicBuffer: UnsafeMutablePointer<QUIC_BUFFER>

        init(_ c: CheckedContinuation<Void, Error>?, data: Data) {
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
            if let existing = state.receiveStream {
                return existing
            }
            // Should not happen if initialized correctly.
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            state.receiveStream = stream
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
        internalState.withLock { state in
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            state.receiveStream = stream
            state.receiveContinuation = continuation
        }
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

    /// Sends data on the stream without waiting for completion.
    ///
    /// Unlike ``send(_:flags:)-async``, this method returns immediately after queuing the data
    /// to MsQuic. The buffer is automatically freed when MsQuic fires the send-complete callback.
    /// MsQuic guarantees FIFO ordering, so multiple calls to this method will be sent in order.
    ///
    /// - Parameters:
    ///   - data: The data to send.
    ///   - flags: Flags controlling send behavior. Use `.fin` to indicate this is the last send.
    /// - Throws: ``QuicError`` if the send cannot be queued.
    public func send(_ data: Data, flags: QuicSendFlags = .none) throws {
        guard let handle = handle else { throw QuicError.invalidState }

        let context = SendContext(nil, data: data)
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
            throw QuicError(status: status)
        }
    }

    /// Sets the stream priority for send scheduling.
    ///
    /// Higher values are sent before lower values. Valid range is `0...0xFFFF`.
    ///
    /// - Parameter priority: The new stream priority.
    /// - Throws: ``QuicError`` if the stream is invalid or MsQuic rejects the parameter.
    public func setPriority(_ priority: UInt16) throws {
        guard let handle = handle else { throw QuicError.invalidState }

        var rawPriority = priority
        let status = QuicStatus(
            api.SetParam(
                handle,
                UInt32(QUIC_PARAM_STREAM_PRIORITY),
                UInt32(MemoryLayout.size(ofValue: rawPriority)),
                &rawPriority
            )
        )
        try status.throwIfFailed()
    }

    /// Gets the current stream priority used for send scheduling.
    ///
    /// - Returns: The current priority value (`0...0xFFFF`).
    /// - Throws: ``QuicError`` if the stream is invalid or MsQuic fails.
    public func getPriority() throws -> UInt16 {
        guard let handle = handle else { throw QuicError.invalidState }

        var rawPriority: UInt16 = 0
        var bufferLength = UInt32(MemoryLayout.size(ofValue: rawPriority))

        let status = QuicStatus(
            api.GetParam(
                handle,
                UInt32(QUIC_PARAM_STREAM_PRIORITY),
                &bufferLength,
                &rawPriority
            )
        )
        try status.throwIfFailed()

        guard bufferLength == UInt32(MemoryLayout.size(ofValue: rawPriority)) else {
            throw QuicError.invalidState
        }

        return rawPriority
    }
    
    /// Shuts down the stream with the given flags.
    ///
    /// Use `.graceful` to finish sending, or `.abort` to abort both directions immediately.
    ///
    /// - Parameters:
    ///   - flags: Shutdown behavior flags. Default is `.abort`.
    ///   - errorCode: An optional application-defined error code to send to the peer.
    public func shutdown(flags: QuicStreamShutdownFlags = .abort, errorCode: UInt64 = 0) async {
        guard let handle = handle else { return }

        await withCheckedContinuation { continuation in
            let action = internalState.withLock { state -> ShutdownAction in
                switch state.streamState {
                case .closed, .shuttingDown:
                    return .resumeImmediately
                default:
                    let previousState = state.streamState
                    state.shutdownContinuation = continuation
                    state.streamState = .shuttingDown
                    return .call(previousState: previousState)
                }
            }

            guard case .call(let previousState) = action else {
                continuation.resume()
                return
            }

            let status = QuicStatus(
                api.StreamShutdown(
                    handle,
                    QUIC_STREAM_SHUTDOWN_FLAGS(flags.rawValue),
                    errorCode
                )
            )

            if status.failed {
                let continuationToResume = internalState.withLock { state -> CheckedContinuation<Void, Never>? in
                    let c = state.shutdownContinuation
                    state.shutdownContinuation = nil
                    state.streamState = previousState
                    return c
                }
                continuationToResume?.resume()
            }
        }
    }
   
    internal func handleEvent(_ event: QUIC_STREAM_EVENT) -> QuicStatus {
        // Send completion is dispatched directly from the raw event so we can
        // read `ClientContext` before it is dropped by the converter. This
        // keeps the public `QuicStreamEvent` free of raw pointers.
        if event.Type == QUIC_STREAM_EVENT_SEND_COMPLETE {
            let rawSend = event.SEND_COMPLETE
            if let rawContext = rawSend.ClientContext {
                let sendContext = Unmanaged<SendContext>.fromOpaque(rawContext).takeRetainedValue()
                if let continuation = sendContext.continuation {
                    if rawSend.Canceled != 0 {
                        continuation.resume(throwing: QuicError.aborted)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

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

        case .sendComplete:
            // Already dispatched at the top of `handleEvent` from the raw
            // event so that the continuation could be resumed without
            // carrying an `UnsafeMutableRawPointer?` on the public enum.
            break
            
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
            // Release self-ref synchronously before resuming the continuation.
            // The caller still holds a strong reference, so deinit won't fire on the callback thread.
            self.releaseSelfFromCallback()
            continuation?.resume()
            
        default:
            break
        }
        
        return .success
    }
    
    deinit {
        // Drain any pending continuations before closing the handle.
        // All three continuations are pulled out under the lock and resumed
        // outside to avoid deadlocks if the callback thread is racing us.
        let (startCont, shutdownCont, recvCont) = internalState.withLock {
            state -> (
                CheckedContinuation<Void, Error>?,
                CheckedContinuation<Void, Never>?,
                AsyncThrowingStream<Data, Error>.Continuation?
            ) in
            let s = state.startContinuation
            state.startContinuation = nil
            let sh = state.shutdownContinuation
            state.shutdownContinuation = nil
            let r = state.receiveContinuation
            state.receiveContinuation = nil
            return (s, sh, r)
        }
        recvCont?.finish()
        shutdownCont?.resume()
        startCont?.resume(throwing: QuicError.aborted)

        if let handle = handle {
            api.StreamClose(handle)
        }
    }
}
