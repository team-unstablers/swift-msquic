//
//  QuicConfiguration.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import SwiftMsQuic

public final class QuicConfiguration: QuicObject {
    public let registration: QuicRegistration
    
    public init(
        registration: QuicRegistration,
        alpnBuffers: [String],
        settings: QuicSettings? = nil
    ) throws {
        self.registration = registration
        super.init()
        
        guard let regHandle = registration.handle else {
            throw QuicError.invalidState
        }
        
        let alpnQuicBuffers = alpnBuffers.map { QuicBuffer($0) }
        
        try withQuicBufferArray(alpnQuicBuffers) { buffersPtr, bufferCount in
            try (settings ?? QuicSettings()).withUnsafeSettings { settingsPtr in
                // If settings is nil, we can pass nil to MsQuic, 
                // but QuicSettings().withUnsafeSettings passes a default struct.
                // MsQuic allows settings to be NULL.
                // My withUnsafeSettings implementation passes a pointer to a struct.
                // If the user didn't provide settings, passing a default struct (with 0 IsSetFlags) is fine.
                // However, passing actual NULL might be slightly more efficient if MsQuic checks for it.
                // But let's stick to passing the struct for uniformity.
                
                var handle: HQUIC? = nil
                
                // Note: The settingsPtr argument in ConfigurationOpen is optional (can be NULL).
                // My helper provides a valid pointer.
                
                let status = QuicStatus(
                    api.ConfigurationOpen(
                        regHandle,
                        buffersPtr,
                        bufferCount,
                        settings != nil ? settingsPtr : nil,
                        settings != nil ? UInt32(MemoryLayout<QUIC_SETTINGS>.size) : 0,
                        nil, // Context
                        &handle
                    )
                )
                
                try status.throwIfFailed()
                self.handle = handle
            }
        }
    }
    
    public func loadCredential(_ credential: QuicCredentialConfig) throws {
        guard let handle = handle else { throw QuicError.invalidState }
        
        try credential.withUnsafeCredentialConfig { credConfigPtr in
            let status = QuicStatus(
                api.ConfigurationLoadCredential(
                    handle,
                    credConfigPtr
                )
            )
            try status.throwIfFailed()
        }
    }
    
    deinit {
        if let handle = handle {
            api.ConfigurationClose(handle)
        }
    }
}
