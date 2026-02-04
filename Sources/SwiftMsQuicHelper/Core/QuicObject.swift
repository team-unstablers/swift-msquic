//
//  QuicObject.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic
import os

/// Base class for all QUIC handle wrappers.
///
/// `QuicObject` provides common functionality for all QUIC objects, including
/// handle management and self-retention for callback safety.
///
/// - Note: This class is typically not used directly. Use the concrete subclasses
///   like ``QuicConnection``, ``QuicStream``, or ``QuicListener`` instead.
open class QuicObject: CInteropHandle {
    /// Internal MsQuic Handle
    internal var handle: HQUIC?

    /// Convenience accessor for the API table
    internal var api: QUIC_API_TABLE { SwiftMsQuicAPI.MsQuic }

    private struct RetainState: @unchecked Sendable {
        var retainedSelf: Unmanaged<AnyObject>?
    }
    private let retainState = OSAllocatedUnfairLock(initialState: RetainState())

    /// Whether this object has a valid handle.
    public var isValid: Bool { handle != nil }
    
    public init() {
        self.handle = nil
    }
    
    internal init(handle: HQUIC) {
        self.handle = handle
    }
    
    deinit {
        // Subclasses must override this to call the appropriate Close function
        // e.g., api.ConnectionClose(handle)
        // Since we cannot call virtual methods in deinit safely in some languages, 
        // but Swift allows it. However, it's better if subclasses handle their specific close logic.
        // We just ensure handle is nullified if we were doing manual management, but here ARC does the job.
        //
        // NOTE: We cannot enforce subclasses to call close() here. 
        // Subclasses SHOULD implement deinit { close() } or similar.
    }
    
    /// Retain self for callback lifetime to avoid use-after-free.
    internal func retainSelfForCallback() {
        retainState.withLock { state in
            guard state.retainedSelf == nil else { return }
            state.retainedSelf = Unmanaged.passRetained(self as AnyObject)
        }
    }
    
    /// Release previously retained self. Safe to call multiple times.
    internal func releaseSelfFromCallback() {
        let retained = retainState.withLock { state -> Unmanaged<AnyObject>? in
            let retained = state.retainedSelf
            state.retainedSelf = nil
            return retained
        }
        retained?.release()
    }
}
