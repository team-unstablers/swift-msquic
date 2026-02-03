//
//  QuicConnection.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic
import os

public final class QuicConnection: QuicObject {
    public enum State: Sendable {
        case idle
        case connecting
        case connected
        case shuttingDown
        case closed
    }
    
    private struct InternalState: Sendable {
        var connectionState: State = .idle
        var connectContinuation: CheckedContinuation<Void, Error>?
        var shutdownContinuation: CheckedContinuation<Void, Never>?
    }
    
    private let internalState = OSAllocatedUnfairLock(initialState: InternalState())
    
    public var state: State {
        internalState.withLock { $0.connectionState }
    }
    
    public let registration: QuicRegistration?
    
    public typealias StreamHandler = (QuicConnection, QuicStream) async -> Void
    private var peerStreamHandler: StreamHandler?
    
    public typealias EventHandler = (QuicConnection, QuicConnectionEvent) -> QuicStatus
    private var eventHandler: EventHandler?
    
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
    
    public init(handle: HQUIC, configuration: QuicConfiguration, streamHandler: StreamHandler? = nil) throws {
        self.registration = configuration.registration
        super.init(handle: handle)
        retainSelfForCallback()
        
        self.peerStreamHandler = streamHandler
        
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
    
    public func openStream(flags: QuicStreamOpenFlags = .none) throws -> QuicStream {
        return try QuicStream(connection: self, flags: flags)
    }
    
    public func onPeerStreamStarted(_ handler: @escaping StreamHandler) {
        self.peerStreamHandler = handler
    }
    
    public func onEvent(_ handler: @escaping EventHandler) {
        self.eventHandler = handler
    }
    
    internal func handleEvent(_ event: QUIC_CONNECTION_EVENT) -> QuicStatus {
        let swiftEvent = QuicEventConverter.convert(event)
        
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
            let (shutdownContinuation, connectContinuation) = internalState.withLock { state -> (CheckedContinuation<Void, Never>?, CheckedContinuation<Void, Error>?) in
                state.connectionState = .closed
                let sc = state.shutdownContinuation
                state.shutdownContinuation = nil
                
                let cc = state.connectContinuation
                state.connectContinuation = nil
                
                return (sc, cc)
            }
            shutdownContinuation?.resume()
            connectContinuation?.resume(throwing: QuicError.aborted)
            
            Task {
                self.releaseSelfFromCallback()
            }
            
        case .peerStreamStarted(let streamHandle, _):
            if let handler = peerStreamHandler {
                let stream = QuicStream(handle: streamHandle)
                Task {
                    await handler(self, stream)
                }
            }
            
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
