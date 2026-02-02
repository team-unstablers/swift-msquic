//
//  QuicRegistration.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import SwiftMsQuic

public final class QuicRegistration: QuicObject {
    
    public init(config: QuicRegistrationConfig) throws {
        super.init()
        
        try config.appName.withCString { appNameCStr in
            var regConfig = QUIC_REGISTRATION_CONFIG(
                AppName: appNameCStr,
                ExecutionProfile: config.executionProfile.asLibEnum
            )
            
            var handle: HQUIC? = nil
            let status = QuicStatus(api.RegistrationOpen(&regConfig, &handle))
            try status.throwIfFailed()
            
            self.handle = handle
        }
    }
    
    public func shutdown(silent: Bool = false, errorCode: UInt64 = 0) {
        guard let handle = handle else { return }
        
        var flags = QUIC_CONNECTION_SHUTDOWN_FLAG_NONE
        if silent {
            flags = QUIC_CONNECTION_SHUTDOWN_FLAG_SILENT
        }
        
        // Use RegistrationShutdown to gracefully (or silently) shut down all connections
        api.RegistrationShutdown(
            handle,
            flags,
            errorCode
        )
    }
    
    deinit {
        if let handle = handle {
            // MsQuic.RegistrationClose blocks until all child objects are closed.
            // This can deadlock if called from a callback.
            // Since this is deinit, we assume we are not in a callback (or user is responsible).
            api.RegistrationClose(handle)
        }
    }
}
