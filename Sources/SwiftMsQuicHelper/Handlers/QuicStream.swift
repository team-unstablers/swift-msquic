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
/// - ``enqueue(_:)``
/// - ``drain(finalFlags:)``
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

    private static let nonBufferedBootstrapWindowBytes: UInt64 = 64 * 1024
    private static let nonBufferedQueueWindowMultiplier: UInt64 = 4

    private struct InternalState: Sendable {
        var streamState: State = .idle
        var startContinuation: CheckedContinuation<Void, Error>?
        var shutdownContinuation: CheckedContinuation<Void, Never>?
        var receiveContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        var activeSingleSendCount: Int = 0

        var idealSendBufferBytes: UInt64 = 0
        var drainQueuedData: [Data] = []
        var drainQueuedBytes: UInt64 = 0
        var drainInFlightBytes: UInt64 = 0
        var drainInFlightCount: Int = 0
        var drainPendingFinalFlags: QuicSendFlags = .none
        var drainContinuation: CheckedContinuation<Void, Error>?
        var drainSendContextTokens: Set<UInt> = []
        var enqueueBlockedForFinalDrain: Bool = false
    }
    private var stateLock = os_unfair_lock_s()
    private var internalState = InternalState()

    @inline(__always)
    private func withStateLock<T>(_ body: (inout InternalState) throws -> T) rethrows -> T {
        os_unfair_lock_lock(&stateLock)
        defer { os_unfair_lock_unlock(&stateLock) }
        return try body(&internalState)
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
        let storage: NSData
        let quicBuffer: UnsafeMutablePointer<QUIC_BUFFER>
        
        init(_ c: CheckedContinuation<Void, Error>, data: Data) {
            self.continuation = c
            self.storage = data as NSData
            self.quicBuffer = UnsafeMutablePointer<QUIC_BUFFER>.allocate(capacity: 1)
            let bytePtr: UnsafeMutablePointer<UInt8>? = data.count > 0
                ? UnsafeMutablePointer<UInt8>(mutating: storage.bytes.assumingMemoryBound(to: UInt8.self))
                : nil
            self.quicBuffer.initialize(to: QUIC_BUFFER(Length: UInt32(data.count), Buffer: bytePtr))
        }
        
        deinit {
            quicBuffer.deinitialize(count: 1)
            quicBuffer.deallocate()
        }
    }

    private class DrainSendContext {
        let byteCount: UInt64
        let storage: NSData
        let quicBuffer: UnsafeMutablePointer<QUIC_BUFFER>

        init(data: Data) {
            self.byteCount = UInt64(data.count)
            self.storage = data as NSData
            self.quicBuffer = UnsafeMutablePointer<QUIC_BUFFER>.allocate(capacity: 1)
            let bytePtr: UnsafeMutablePointer<UInt8>? = data.count > 0
                ? UnsafeMutablePointer<UInt8>(mutating: storage.bytes.assumingMemoryBound(to: UInt8.self))
                : nil
            self.quicBuffer.initialize(to: QUIC_BUFFER(Length: UInt32(data.count), Buffer: bytePtr))
        }

        deinit {
            quicBuffer.deinitialize(count: 1)
            quicBuffer.deallocate()
        }
    }

    private enum DrainPumpAction {
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

    private func ensureNonBufferedSendAvailable() throws {
        let effectiveHint: Bool? = sendBufferingEnabledHint ?? connection?.currentSendBufferingEnabledSetting()
        guard effectiveHint == false else {
            throw QuicError.invalidState
        }
    }

    private static func drainWindowBytes(for idealSendBufferBytes: UInt64) -> UInt64 {
        max(1, max(idealSendBufferBytes, nonBufferedBootstrapWindowBytes))
    }

    private static func maxQueuedBytes(for idealSendBufferBytes: UInt64) -> UInt64 {
        let window = drainWindowBytes(for: idealSendBufferBytes)
        let (maxQueuedBytes, overflow) = window.multipliedReportingOverflow(by: nonBufferedQueueWindowMultiplier)
        return overflow ? UInt64.max : maxQueuedBytes
    }

    private func abortDrainLocked(_ state: inout InternalState) -> CheckedContinuation<Void, Error>? {
        let continuation = state.drainContinuation
        state.drainContinuation = nil
        state.drainQueuedData.removeAll()
        state.drainQueuedBytes = 0
        state.drainInFlightBytes = 0
        state.drainInFlightCount = 0
        state.drainPendingFinalFlags = .none
        state.enqueueBlockedForFinalDrain = false
        return continuation
    }

    private func reserveNextDrainAction() -> DrainPumpAction {
        withStateLock { state in
            guard let continuation = state.drainContinuation else {
                return .idle
            }

            if let nextChunk = state.drainQueuedData.first {
                let nextChunkBytes = UInt64(nextChunk.count)
                let windowBytes = Self.drainWindowBytes(for: state.idealSendBufferBytes)
                let wouldExceedWindow = state.drainInFlightBytes + nextChunkBytes > windowBytes

                if state.drainInFlightCount > 0 && wouldExceedWindow {
                    return .idle
                }

                let consumeFinalFlags = state.drainPendingFinalFlags != .none && state.drainQueuedData.count == 1
                let flags = consumeFinalFlags ? state.drainPendingFinalFlags : .none
                if consumeFinalFlags {
                    state.drainPendingFinalFlags = .none
                }

                state.drainQueuedData.removeFirst()
                if state.drainQueuedBytes >= nextChunkBytes {
                    state.drainQueuedBytes -= nextChunkBytes
                } else {
                    state.drainQueuedBytes = 0
                }
                state.drainInFlightCount += 1
                state.drainInFlightBytes += nextChunkBytes

                return .sendChunk(nextChunk, flags)
            }

            if state.drainInFlightCount > 0 {
                return .idle
            }

            if state.drainPendingFinalFlags != .none {
                let flags = state.drainPendingFinalFlags
                state.drainPendingFinalFlags = .none
                state.drainInFlightCount += 1
                return .sendChunk(Data(), flags)
            }

            state.drainContinuation = nil
            state.enqueueBlockedForFinalDrain = false
            return .complete(continuation)
        }
    }

    private func pumpDrainSend() {
        while true {
            guard let handle else {
                let continuation = withStateLock { state -> CheckedContinuation<Void, Error>? in
                    abortDrainLocked(&state)
                }
                continuation?.resume(throwing: QuicError.invalidState)
                return
            }

            switch reserveNextDrainAction() {
            case .idle:
                return

            case .complete(let continuation):
                continuation.resume()
                return

            case .sendChunk(let data, let flags):
                let context = DrainSendContext(data: data)
                let contextPtr = Unmanaged.passRetained(context as AnyObject).toOpaque()
                let contextToken = UInt(bitPattern: contextPtr)

                _ = withStateLock {
                    $0.drainSendContextTokens.insert(contextToken)
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
                        $0.drainSendContextTokens.remove(contextToken)
                    }
                    let continuation = withStateLock { state in
                        abortDrainLocked(&state)
                    }
                    continuation?.resume(throwing: QuicError(status: status))
                    return
                }
            }
        }
    }

    private func finishDrainChunk(token: UInt, byteCount: UInt64, canceled: Bool) -> (CheckedContinuation<Void, Error>?, Bool) {
        withStateLock { state in
            state.drainSendContextTokens.remove(token)

            if state.drainInFlightCount > 0 {
                state.drainInFlightCount -= 1
            }
            if state.drainInFlightBytes >= byteCount {
                state.drainInFlightBytes -= byteCount
            } else {
                state.drainInFlightBytes = 0
            }

            guard state.drainContinuation != nil else {
                return (nil, false)
            }

            if canceled {
                return (abortDrainLocked(&state), false)
            }

            if !state.drainQueuedData.isEmpty || state.drainPendingFinalFlags != .none {
                return (nil, true)
            }

            if state.drainInFlightCount > 0 {
                return (nil, false)
            }

            let continuation = state.drainContinuation
            state.drainContinuation = nil
            state.enqueueBlockedForFinalDrain = false
            return (continuation, false)
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
    /// - Important: Do not call this concurrently with ``enqueue(_:)`` / ``drain(finalFlags:)`` on the same stream.
    ///
    /// - Parameters:
    ///   - data: The data to send.
    ///   - flags: Flags controlling send behavior. Use `.fin` to indicate this is the last send.
    /// - Throws: ``QuicError`` if the send fails.
    public func send(_ data: Data, flags: QuicSendFlags = .none) async throws {
        guard let handle = handle else { throw QuicError.invalidState }

        return try await withCheckedThrowingContinuation { continuation in
            let canSend = withStateLock { state -> Bool in
                guard state.drainContinuation == nil else {
                    return false
                }
                guard state.drainQueuedData.isEmpty else {
                    return false
                }
                guard state.drainInFlightCount == 0 else {
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

    /// Enqueues data for non-buffered drain-mode sending.
    ///
    /// The data reference is retained by the stream until sent via ``drain(finalFlags:)``.
    ///
    /// This API is only available when the stream's connection uses
    /// `QuicSettings.sendBufferingEnabled = false`.
    ///
    /// - Parameter data: A chunk to append to the pending send queue.
    /// - Throws: ``QuicError`` if buffering mode is incompatible, the queue is over limit, or the stream is in an invalid state.
    public func enqueue(_ data: Data) throws {
        guard handle != nil else {
            throw QuicError.invalidState
        }
        guard data.count <= Int(UInt32.max) else {
            throw QuicError.invalidParameter
        }
        try ensureNonBufferedSendAvailable()

        let byteCount = UInt64(data.count)

        try withStateLock { state in
            guard state.activeSingleSendCount == 0 else {
                throw QuicError.invalidState
            }
            guard !state.enqueueBlockedForFinalDrain else {
                throw QuicError.invalidState
            }

            let queueLimit = Self.maxQueuedBytes(for: state.idealSendBufferBytes)
            if state.drainQueuedBytes + byteCount > queueLimit {
                throw QuicError.invalidState
            }

            state.drainQueuedData.append(data)
            state.drainQueuedBytes += byteCount
        }
    }

    /// Starts draining queued chunks using IDEAL_SEND_BUFFER_SIZE-based in-flight windowing.
    ///
    /// This API is only available when the stream's connection uses
    /// `QuicSettings.sendBufferingEnabled = false`.
    ///
    /// `drain` returns only when all queued chunks and in-flight sends complete.
    /// If `finalFlags` is non-empty, the flags are applied to the final send in this drain cycle.
    ///
    /// - Parameter finalFlags: Optional flags applied to the final send of this drain cycle.
    /// - Throws: ``QuicError`` if buffering mode is incompatible, a drain is already active, or send fails.
    public func drain(finalFlags: QuicSendFlags = .none) async throws {
        guard handle != nil else {
            throw QuicError.invalidState
        }
        try ensureNonBufferedSendAvailable()

        return try await withCheckedThrowingContinuation { continuation in
            let canStart = withStateLock { state -> Bool in
                guard state.activeSingleSendCount == 0 else {
                    return false
                }
                guard state.drainContinuation == nil else {
                    return false
                }

                state.drainContinuation = continuation
                state.drainPendingFinalFlags = finalFlags
                state.enqueueBlockedForFinalDrain = finalFlags != .none
                return true
            }

            guard canStart else {
                continuation.resume(throwing: QuicError.invalidState)
                return
            }

            pumpDrainSend()
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
                } else if let drainContext = retained as? DrainSendContext {
                    let (continuation, shouldPump) = finishDrainChunk(
                        token: contextToken,
                        byteCount: drainContext.byteCount,
                        canceled: canceled
                    )

                    if let continuation {
                        if canceled {
                            continuation.resume(throwing: QuicError.aborted)
                        } else {
                            continuation.resume()
                        }
                    } else if shouldPump {
                        pumpDrainSend()
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
                return state.drainContinuation != nil
            }
            if shouldPump {
                pumpDrainSend()
            }

        case .shutdownComplete:
            let (shutdownContinuation, drainContinuation) = withStateLock { state -> (CheckedContinuation<Void, Never>?, CheckedContinuation<Void, Error>?) in
                state.streamState = .closed
                let c = state.shutdownContinuation
                state.shutdownContinuation = nil
                let drain = abortDrainLocked(&state)
                return (c, drain)
            }
            shutdownContinuation?.resume()
            drainContinuation?.resume(throwing: QuicError.aborted)
            Task {
                self.releaseSelfFromCallback()
            }

        default:
            break
        }

        return .success
    }

    deinit {
        let (receiveContinuation, shutdownContinuation, drainContinuation, drainTokens) = withStateLock { state in
            let receive = state.receiveContinuation
            state.receiveContinuation = nil

            let shutdown = state.shutdownContinuation
            state.shutdownContinuation = nil

            let drain = abortDrainLocked(&state)

            let tokens = Array(state.drainSendContextTokens)
            state.drainSendContextTokens.removeAll()

            return (receive, shutdown, drain, tokens)
        }

        for token in drainTokens {
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
        drainContinuation?.resume(throwing: QuicError.aborted)
    }
}
