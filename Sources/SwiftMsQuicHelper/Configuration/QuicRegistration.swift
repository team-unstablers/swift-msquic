//
//  QuicRegistration.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic

/// A registration that groups QUIC objects together for resource management.
///
/// `QuicRegistration` is the top-level container for QUIC operations. All configurations,
/// listeners, and connections must be associated with a registration.
///
/// Create a registration early in your application and keep it alive for the duration
/// of your QUIC operations.
///
/// ## Example
///
/// ```swift
/// let registration = try QuicRegistration(config: .init(
///     appName: "MyApp",
///     executionProfile: .lowLatency
/// ))
/// ```
///
/// ## Topics
///
/// ### Creating Registrations
///
/// - ``init(config:)``
///
/// ### Managing Registration Lifecycle
///
/// - ``shutdown(silent:errorCode:)``
public final class QuicRegistration: QuicObject {

    /// Creates a new registration with the specified configuration.
    ///
    /// - Parameter config: The configuration for this registration.
    /// - Throws: ``QuicError`` if the registration cannot be created.
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
    
    /// Shuts down all connections in this registration.
    ///
    /// This method gracefully or silently closes all connections associated with this registration.
    ///
    /// - Parameters:
    ///   - silent: If `true`, connections are closed without sending a close frame to peers.
    ///   - errorCode: An optional application-defined error code to send to peers.
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
