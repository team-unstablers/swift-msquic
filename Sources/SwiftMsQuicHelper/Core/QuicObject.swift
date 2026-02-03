//
//  QuicObject.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic

open class QuicObject: CInteropHandle {
    /// Internal MsQuic Handle
    internal var handle: HQUIC?
    
    /// Convenience accessor for the API table
    internal var api: QUIC_API_TABLE { SwiftMsQuicAPI.MsQuic }
    
    private let retainLock = NSLock()
    private var retainedSelf: Unmanaged<AnyObject>?
    
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
        retainLock.lock()
        defer { retainLock.unlock() }
        guard retainedSelf == nil else { return }
        retainedSelf = Unmanaged.passRetained(self as AnyObject)
    }
    
    /// Release previously retained self. Safe to call multiple times.
    internal func releaseSelfFromCallback() {
        retainLock.lock()
        let retained = retainedSelf
        retainedSelf = nil
        retainLock.unlock()
        
        retained?.release()
    }
}
