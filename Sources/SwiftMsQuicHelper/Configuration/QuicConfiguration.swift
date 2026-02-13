//
//  QuicConfiguration.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic

/// Configuration for QUIC connections and listeners.
///
/// `QuicConfiguration` holds the ALPN protocols, TLS credentials, and QUIC settings
/// used by connections and listeners. Each configuration is associated with a
/// ``QuicRegistration``.
///
/// ## Creating a Configuration
///
/// ```swift
/// var settings = QuicSettings()
/// settings.idleTimeoutMs = 30000
///
/// let config = try QuicConfiguration(
///     registration: registration,
///     alpnBuffers: ["my-protocol"],
///     settings: settings
/// )
///
/// // Load TLS credentials
/// try config.loadCredential(.init(
///     type: .certificateFile(certPath: "server.crt", keyPath: "server.key"),
///     flags: []
/// ))
/// ```
///
/// ## Topics
///
/// ### Creating Configurations
///
/// - ``init(registration:alpnBuffers:settings:)``
///
/// ### Loading Credentials
///
/// - ``loadCredential(_:)``
public final class QuicConfiguration: QuicObject {
    /// The registration this configuration belongs to.
    public let registration: QuicRegistration

    /// Whether MsQuic stream send buffering is enabled for this configuration.
    ///
    /// `nil` means the default MsQuic behavior is used.
    internal let sendBufferingEnabled: Bool?

    /// Creates a new configuration.
    ///
    /// - Parameters:
    ///   - registration: The registration to associate with this configuration.
    ///   - alpnBuffers: The list of supported ALPN protocol names.
    ///   - settings: Optional QUIC settings. If `nil`, default settings are used.
    /// - Throws: ``QuicError`` if the configuration cannot be created.
    public init(
        registration: QuicRegistration,
        alpnBuffers: [String],
        settings: QuicSettings? = nil
    ) throws {
        self.registration = registration
        self.sendBufferingEnabled = settings?.sendBufferingEnabled
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
    
    /// Loads TLS credentials into this configuration.
    ///
    /// Call this method after creating the configuration to set up TLS.
    /// For servers, this typically involves loading a certificate and private key.
    /// For clients, this may involve setting up certificate validation options.
    ///
    /// - Parameter credential: The credential configuration to load.
    /// - Throws: ``QuicError`` if the credentials cannot be loaded.
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
