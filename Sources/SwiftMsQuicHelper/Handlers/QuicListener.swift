//
//  QuicListener.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic
import os

public final class QuicListener: QuicObject {
    public let registration: QuicRegistration
    
    public typealias ConnectionHandler = (QuicListener, QuicListenerEvent.NewConnectionInfo) async throws -> QuicConnection?
    
    private var connectionHandler: ConnectionHandler?
    
    private struct State: Sendable {
        var stopContinuation: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    
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
    }
    
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
    
    public func stop() async {
        guard let handle = handle else { return }
        
        await withCheckedContinuation { continuation in
            state.withLock {
                $0.stopContinuation = continuation
            }
            
            api.ListenerStop(handle)
        }
    }
    
    public func onNewConnection(_ handler: @escaping ConnectionHandler) {
        self.connectionHandler = handler
    }
    
    internal func handleEvent(_ event: QUIC_LISTENER_EVENT) -> QuicStatus {
        let swiftEvent = QuicEventConverter.convert(event)
        
        switch swiftEvent {
        case .newConnection(let info):
            guard let handler = connectionHandler else {
                return .connectionRefused
            }
            
            Task {
                do {
                    if let _ = try await handler(self, info) {
                        // Accepted
                    } else {
                        // Rejected
                        api.ConnectionClose(info.connection)
                    }
                } catch {
                    api.ConnectionClose(info.connection)
                }
            }
            return .pending
            
        case .stopComplete:
            let continuation = state.withLock {
                let c = $0.stopContinuation
                $0.stopContinuation = nil
                return c
            }
            continuation?.resume()
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
