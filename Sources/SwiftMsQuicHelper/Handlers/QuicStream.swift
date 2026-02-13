//
//  QuicStream.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic
#if canImport(Darwin)
import Darwin
#endif

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
/// - ``sendChunks(_:finalFlags:options:)``
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

    /// Options for non-buffered, windowed multi-send.
    ///
    /// `bootstrapWindowBytes` is used until MsQuic reports
    /// `QUIC_STREAM_EVENT_IDEAL_SEND_BUFFER_SIZE`.
    public struct NonBufferedSendOptions: Sendable {
        /// Temporary in-flight send window used before the first ideal window update.
        public var bootstrapWindowBytes: UInt64

        /// Creates new options for non-buffered send windowing.
        ///
        /// - Parameter bootstrapWindowBytes: Initial in-flight byte window before ideal size is known.
        public init(bootstrapWindowBytes: UInt64 = 64 * 1024) {
            self.bootstrapWindowBytes = bootstrapWindowBytes
        }
    }

    private struct WindowedSendOperation {
        var chunks: [Data]
        var nextChunkIndex: Int
        var inFlightBytes: UInt64
        var inFlightChunkCount: Int
        let finalFlags: QuicSendFlags
        let options: NonBufferedSendOptions
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct InternalState: Sendable {
        var streamState: State = .idle
        var startContinuation: CheckedContinuation<Void, Error>?
        var shutdownContinuation: CheckedContinuation<Void, Never>?
        var receiveContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        var activeSingleSendCount: Int = 0
        var idealSendBufferBytes: UInt64 = 0
        var windowedSendOperation: WindowedSendOperation?
        var windowedSendContextTokens: Set<UInt> = []
    }
    private var stateLock = os_unfair_lock_s()
    private var internalState = InternalState()

    @inline(__always)
    private func withStateLock<T>(_ body: (inout InternalState) -> T) -> T {
        os_unfair_lock_lock(&stateLock)
        defer { os_unfair_lock_unlock(&stateLock) }
        return body(&internalState)
    }

    /// The current state of the stream.
    public var state: State {
        withStateLock { $0.streamState }
    }

    /// The connection this stream belongs to, if known.
    ///
    /// This is `nil` for streams received from a peer, as they are created
    /// with just the handle.
    public let connection: QuicConnection?

    private let sendBufferingEnabledHint: Bool?

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

    private class WindowedSendChunkContext {
        let byteCount: UInt64
        let buffer: UnsafeMutableRawBufferPointer
        let quicBuffer: UnsafeMutablePointer<QUIC_BUFFER>

        init(data: Data) {
            self.byteCount = UInt64(data.count)
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

    private enum WindowedPumpAction {
        case idle
        case complete(CheckedContinuation<Void, Error>)
        case sendChunk(Data, QuicSendFlags)
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
        withStateLock { state in
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
        self.sendBufferingEnabledHint = nil
        super.init(handle: handle)
        retainSelfForCallback()

        typealias StreamCallback = @convention(c) (HQUIC?, UnsafeMutableRawPointer?, UnsafeMutablePointer<QUIC_STREAM_EVENT>?) -> QuicStatusRawValue
        let callback = quicStreamCallback as StreamCallback
        let callbackPtr = unsafeBitCast(callback, to: UnsafeMutableRawPointer.self)

        api.SetCallbackHandler(handle, callbackPtr, self.asCInteropHandle)

        initReceiveStream()

        withStateLock { $0.streamState = .open }
    }

    internal init(peerHandle handle: HQUIC, connection: QuicConnection, sendBufferingEnabledHint: Bool?) {
        self.connection = connection
        self.sendBufferingEnabledHint = sendBufferingEnabledHint
        super.init(handle: handle)
        retainSelfForCallback()

        typealias StreamCallback = @convention(c) (HQUIC?, UnsafeMutableRawPointer?, UnsafeMutablePointer<QUIC_STREAM_EVENT>?) -> QuicStatusRawValue
        let callback = quicStreamCallback as StreamCallback
        let callbackPtr = unsafeBitCast(callback, to: UnsafeMutableRawPointer.self)

        api.SetCallbackHandler(handle, callbackPtr, self.asCInteropHandle)

        initReceiveStream()

        withStateLock { $0.streamState = .open }
    }

    internal init(connection: QuicConnection, flags: QuicStreamOpenFlags) throws {
        self.connection = connection
        self.sendBufferingEnabledHint = connection.currentSendBufferingEnabledSetting()
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
        withStateLock { $0.receiveContinuation = continuation }
    }

    private func ensureWindowedSendAvailable() throws {
        let effectiveHint: Bool? = sendBufferingEnabledHint ?? connection?.currentSendBufferingEnabledSetting()
        guard effectiveHint == false else {
            throw QuicError.invalidState
        }
    }

    private func reserveNextWindowedSendAction() -> WindowedPumpAction {
        withStateLock { state in
            guard var operation = state.windowedSendOperation else {
                return .idle
            }

            if operation.nextChunkIndex >= operation.chunks.count {
                if operation.inFlightChunkCount == 0 {
                    state.windowedSendOperation = nil
                    return .complete(operation.continuation)
                }
                state.windowedSendOperation = operation
                return .idle
            }

            let initialWindow = max(1, operation.options.bootstrapWindowBytes)
            let windowBytes = max(state.idealSendBufferBytes, initialWindow)
            let nextChunk = operation.chunks[operation.nextChunkIndex]
            let nextChunkBytes = UInt64(nextChunk.count)
            let wouldExceedWindow = operation.inFlightBytes + nextChunkBytes > windowBytes

            if operation.inFlightChunkCount > 0 && wouldExceedWindow {
                state.windowedSendOperation = operation
                return .idle
            }

            let isLastChunk = operation.nextChunkIndex == operation.chunks.count - 1
            let chunkFlags: QuicSendFlags = isLastChunk ? operation.finalFlags : .none

            operation.nextChunkIndex += 1
            operation.inFlightChunkCount += 1
            operation.inFlightBytes += nextChunkBytes
            state.windowedSendOperation = operation

            return .sendChunk(nextChunk, chunkFlags)
        }
    }

    private func rollbackReservedWindowedChunk(_ byteCount: UInt64) -> CheckedContinuation<Void, Error>? {
        withStateLock { state in
            guard var operation = state.windowedSendOperation else {
                return nil
            }
            if operation.nextChunkIndex > 0 {
                operation.nextChunkIndex -= 1
            }
            if operation.inFlightChunkCount > 0 {
                operation.inFlightChunkCount -= 1
            }
            if operation.inFlightBytes >= byteCount {
                operation.inFlightBytes -= byteCount
            } else {
                operation.inFlightBytes = 0
            }

            state.windowedSendOperation = nil
            return operation.continuation
        }
    }

    private func pumpWindowedSend() {
        while true {
            guard let handle else {
                let continuation = withStateLock { state -> CheckedContinuation<Void, Error>? in
                    guard let operation = state.windowedSendOperation else {
                        return nil
                    }
                    state.windowedSendOperation = nil
                    return operation.continuation
                }
                continuation?.resume(throwing: QuicError.invalidState)
                return
            }

            switch reserveNextWindowedSendAction() {
            case .idle:
                return

            case .complete(let continuation):
                continuation.resume()
                return

            case .sendChunk(let data, let flags):
                let context = WindowedSendChunkContext(data: data)
                let contextPtr = Unmanaged.passRetained(context as AnyObject).toOpaque()
                let contextToken = UInt(bitPattern: contextPtr)

                _ = withStateLock {
                    $0.windowedSendContextTokens.insert(contextToken)
                }

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
                    let _ = Unmanaged<AnyObject>.fromOpaque(contextPtr).takeRetainedValue()
                    _ = withStateLock {
                        $0.windowedSendContextTokens.remove(contextToken)
                    }

                    let continuation = rollbackReservedWindowedChunk(context.byteCount)
                    continuation?.resume(throwing: QuicError(status: status))
                    return
                }
            }
        }
    }

    private func finishWindowedChunk(token: UInt, byteCount: UInt64, canceled: Bool) -> (CheckedContinuation<Void, Error>?, Bool) {
        withStateLock { state in
            state.windowedSendContextTokens.remove(token)

            guard var operation = state.windowedSendOperation else {
                return (nil, false)
            }

            if operation.inFlightChunkCount > 0 {
                operation.inFlightChunkCount -= 1
            }
            if operation.inFlightBytes >= byteCount {
                operation.inFlightBytes -= byteCount
            } else {
                operation.inFlightBytes = 0
            }

            if canceled {
                state.windowedSendOperation = nil
                return (operation.continuation, false)
            }

            if operation.nextChunkIndex >= operation.chunks.count, operation.inFlightChunkCount == 0 {
                state.windowedSendOperation = nil
                return (operation.continuation, false)
            }

            state.windowedSendOperation = operation
            return (nil, true)
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
            withStateLock {
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
                withStateLock {
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
            let canSend = withStateLock { state -> Bool in
                guard state.windowedSendOperation == nil else {
                    return false
                }
                state.activeSingleSendCount += 1
                return true
            }
            guard canSend else {
                continuation.resume(throwing: QuicError.invalidState)
                return
            }

            let context = SendContext(continuation, data: data)
            let contextPtr = Unmanaged.passRetained(context as AnyObject).toOpaque()

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
                let _ = Unmanaged<AnyObject>.fromOpaque(contextPtr).takeRetainedValue()
                withStateLock {
                    if $0.activeSingleSendCount > 0 {
                        $0.activeSingleSendCount -= 1
                    }
                }
                continuation.resume(throwing: QuicError(status: status))
            }
        }
    }

    /// Sends multiple chunks with an IDEAL_SEND_BUFFER_SIZE-based in-flight window.
    ///
    /// This API is only available when the stream's connection uses
    /// `QuicSettings.sendBufferingEnabled = false`.
    ///
    /// - Important: Do not call ``send(_:flags:)`` concurrently with this API on the same stream.
    ///
    /// - Parameters:
    ///   - chunks: Data chunks to send in order.
    ///   - finalFlags: Send flags applied only to the final chunk (for example `.fin`).
    ///   - options: Non-buffered send window options.
    /// - Throws: ``QuicError`` if the stream is invalid, buffering mode is incompatible, or send fails.
    public func sendChunks<S: Sequence>(
        _ chunks: S,
        finalFlags: QuicSendFlags = .none,
        options: NonBufferedSendOptions = .init()
    ) async throws where S.Element == Data {
        guard handle != nil else {
            throw QuicError.invalidState
        }
        guard options.bootstrapWindowBytes > 0 else {
            throw QuicError.invalidParameter
        }
        try ensureWindowedSendAvailable()

        var preparedChunks = Array(chunks)
        for chunk in preparedChunks where chunk.count > Int(UInt32.max) {
            throw QuicError.invalidParameter
        }

        if preparedChunks.isEmpty {
            if finalFlags == .none {
                return
            }
            preparedChunks = [Data()]
        }

        return try await withCheckedThrowingContinuation { continuation in
            let canStart = withStateLock { state -> Bool in
                if state.activeSingleSendCount > 0 {
                    return false
                }
                if state.windowedSendOperation != nil {
                    return false
                }

                state.windowedSendOperation = WindowedSendOperation(
                    chunks: preparedChunks,
                    nextChunkIndex: 0,
                    inFlightBytes: 0,
                    inFlightChunkCount: 0,
                    finalFlags: finalFlags,
                    options: options,
                    continuation: continuation
                )
                return true
            }

            guard canStart else {
                continuation.resume(throwing: QuicError.invalidState)
                return
            }

            pumpWindowedSend()
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
            var previousState: State? = nil
            let shouldCall = withStateLock { state -> Bool in
                switch state.streamState {
                case .closed, .shuttingDown:
                    return false
                default:
                    previousState = state.streamState
                    state.shutdownContinuation = continuation
                    state.streamState = .shuttingDown
                    return true
                }
            }

            guard shouldCall else {
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
                let continuationToResume = withStateLock { state -> CheckedContinuation<Void, Never>? in
                    let c = state.shutdownContinuation
                    state.shutdownContinuation = nil
                    if let previousState {
                        state.streamState = previousState
                    }
                    return c
                }
                continuationToResume?.resume()
            }
        }
    }
   
    internal func handleEvent(_ event: QUIC_STREAM_EVENT) -> QuicStatus {
        let swiftEvent = QuicEventConverter.convert(event)

        switch swiftEvent {
        case .startComplete(let status, _, _):
            let continuation = withStateLock { state -> CheckedContinuation<Void, Error>? in
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
            withStateLock { $0.receiveContinuation }?.yield(data)
            if let handle = handle {
                api.StreamReceiveComplete(handle, totalLength)
                return .pending
            }

        case .sendComplete(let canceled, let context):
            if let context = context {
                let contextToken = UInt(bitPattern: context)
                let retained = Unmanaged<AnyObject>.fromOpaque(context).takeRetainedValue()

                if let sendContext = retained as? SendContext {
                    withStateLock {
                        if $0.activeSingleSendCount > 0 {
                            $0.activeSingleSendCount -= 1
                        }
                    }
                    if canceled {
                        sendContext.continuation.resume(throwing: QuicError.aborted)
                    } else {
                        sendContext.continuation.resume()
                    }
                } else if let windowedContext = retained as? WindowedSendChunkContext {
                    let (continuation, shouldPump) = finishWindowedChunk(
                        token: contextToken,
                        byteCount: windowedContext.byteCount,
                        canceled: canceled
                    )

                    if let continuation {
                        if canceled {
                            continuation.resume(throwing: QuicError.aborted)
                        } else {
                            continuation.resume()
                        }
                    } else if shouldPump {
                        pumpWindowedSend()
                    }
                }
            }

        case .peerSendShutdown:
            withStateLock { $0.receiveContinuation }?.finish()

        case .peerSendAborted(_):
            // TODO: Pass error code
            withStateLock { $0.receiveContinuation }?.finish(throwing: QuicError.aborted)

        case .peerReceiveAborted:
            break

        case .idealSendBufferSize(let byteCount):
            let shouldPump = withStateLock { state -> Bool in
                state.idealSendBufferBytes = byteCount
                return state.windowedSendOperation != nil
            }
            if shouldPump {
                pumpWindowedSend()
            }

        case .shutdownComplete:
            let (shutdownContinuation, sendContinuation) = withStateLock { state -> (CheckedContinuation<Void, Never>?, CheckedContinuation<Void, Error>?) in
                state.streamState = .closed
                let c = state.shutdownContinuation
                state.shutdownContinuation = nil
                let send = state.windowedSendOperation?.continuation
                state.windowedSendOperation = nil
                return (c, send)
            }
            shutdownContinuation?.resume()
            sendContinuation?.resume(throwing: QuicError.aborted)
            Task {
                self.releaseSelfFromCallback()
            }

        default:
            break
        }

        return .success
    }

    deinit {
        let (receiveContinuation, shutdownContinuation, windowedSendContinuation, windowedTokens) = withStateLock { state in
            let receive = state.receiveContinuation
            state.receiveContinuation = nil

            let shutdown = state.shutdownContinuation
            state.shutdownContinuation = nil

            let send = state.windowedSendOperation?.continuation
            state.windowedSendOperation = nil

            let tokens = Array(state.windowedSendContextTokens)
            state.windowedSendContextTokens.removeAll()

            return (receive, shutdown, send, tokens)
        }

        for token in windowedTokens {
            guard let ptr = UnsafeMutableRawPointer(bitPattern: token) else {
                continue
            }
            let _ = Unmanaged<AnyObject>.fromOpaque(ptr).takeRetainedValue()
        }

        if let handle = handle {
            api.StreamClose(handle)
        }

        receiveContinuation?.finish()
        shutdownContinuation?.resume()
        windowedSendContinuation?.resume(throwing: QuicError.aborted)
    }
}
