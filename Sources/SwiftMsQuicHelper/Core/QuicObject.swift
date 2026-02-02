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
}
