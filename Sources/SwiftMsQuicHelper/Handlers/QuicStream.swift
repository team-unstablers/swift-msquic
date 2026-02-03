//
//  QuicStream.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic
import os

public final class QuicStream: QuicObject {
    
    public enum State: Sendable {
        case idle
        case starting
        case open
        case shuttingDown
        case closed
    }
    
    private struct InternalState: Sendable {
        var streamState: State = .idle
        var startContinuation: CheckedContinuation<Void, Error>?
        var shutdownContinuation: CheckedContinuation<Void, Never>?
        var receiveContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    }
    private let internalState = OSAllocatedUnfairLock(initialState: InternalState())
    
    public var state: State {
        internalState.withLock { $0.streamState }
    }
    
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
    
    public func shutdownSend(errorCode: UInt64 = 0) {
        guard let handle = handle else { return }
        _ = api.StreamShutdown(handle, QUIC_STREAM_SHUTDOWN_FLAG_GRACEFUL, errorCode)
    }
    
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
