//
//  QuicCredentialConfig.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic

/// The type of TLS credential to use.
///
/// Use this enum to specify how TLS credentials are provided to MsQuic.
public enum QuicCredentialType {
    /// Certificate and private key from file paths.
    ///
    /// - Parameters:
    ///   - certPath: Path to the certificate file (PEM or other supported format).
    ///   - keyPath: Path to the private key file.
    case certificateFile(certPath: String, keyPath: String)

    /// Certificate and private key from a PKCS#12 blob.
    ///
    /// - Parameters:
    ///   - blob: The PKCS#12 data (ASN.1 encoded).
    ///   - password: Optional password to decrypt the PKCS#12 data.
    case certificatePkcs12(blob: Data, password: String?)

    /// No certificate.
    ///
    /// Use this for client connections or when certificates are not required.
    case none
}

/// Flags that control TLS credential behavior.
///
/// Combine these flags to customize how credentials are loaded and validated.
public struct QuicCredentialFlags: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// No special flags.
    public static let none = QuicCredentialFlags([])

    /// Indicates this is a client-side credential.
    ///
    /// Required when loading credentials for client connections.
    public static let client = QuicCredentialFlags(rawValue: UInt32(QUIC_CREDENTIAL_FLAG_CLIENT.rawValue))

    /// Load credentials asynchronously.
    ///
    /// - Note: Not currently supported by this wrapper.
    public static let loadAsynchronous = QuicCredentialFlags(rawValue: UInt32(QUIC_CREDENTIAL_FLAG_LOAD_ASYNCHRONOUS.rawValue))

    /// Disable certificate validation.
    ///
    /// - Warning: Only use this for testing. Never disable certificate validation in production.
    public static let noCertificateValidation = QuicCredentialFlags(rawValue: UInt32(QUIC_CREDENTIAL_FLAG_NO_CERTIFICATE_VALIDATION.rawValue))

    /// Receive an event when the peer's certificate is received.
    public static let indicateCertificateReceived = QuicCredentialFlags(rawValue: UInt32(QUIC_CREDENTIAL_FLAG_INDICATE_CERTIFICATE_RECEIVED.rawValue))

    /// Defer certificate validation to the application.
    public static let deferCertificateValidation = QuicCredentialFlags(rawValue: UInt32(QUIC_CREDENTIAL_FLAG_DEFER_CERTIFICATE_VALIDATION.rawValue))

    /// Require the client to provide a certificate (server-side).
    public static let requireClientAuthentication = QuicCredentialFlags(rawValue: UInt32(QUIC_CREDENTIAL_FLAG_REQUIRE_CLIENT_AUTHENTICATION.rawValue))
}

/// Configuration for TLS credentials.
///
/// This structure combines a ``QuicCredentialType`` with ``QuicCredentialFlags``
/// to fully specify how TLS should be configured.
///
/// ## Server Example
///
/// ```swift
/// try config.loadCredential(.init(
///     type: .certificateFile(certPath: "server.crt", keyPath: "server.key"),
///     flags: []
/// ))
/// ```
///
/// ## Client Example
///
/// ```swift
/// // Normal client with certificate validation
/// try config.loadCredential(.init(type: .none, flags: [.client]))
///
/// // Testing client without certificate validation
/// try config.loadCredential(.init(
///     type: .none,
///     flags: [.client, .noCertificateValidation]
/// ))
/// ```
public struct QuicCredentialConfig {
    /// The type of credential (certificate file, PKCS#12, or none).
    public let type: QuicCredentialType

    /// Flags controlling credential behavior.
    public let flags: QuicCredentialFlags

    /// Creates a new credential configuration.
    ///
    /// - Parameters:
    ///   - type: The type of credential to use.
    ///   - flags: Flags controlling credential behavior.
    public init(type: QuicCredentialType, flags: QuicCredentialFlags = []) {
        self.type = type
        self.flags = flags
    }
    
    internal func withUnsafeCredentialConfig<T>(_ body: (UnsafePointer<QUIC_CREDENTIAL_CONFIG>) throws -> T) throws -> T {
        if flags.contains(.loadAsynchronous) {
            // Async credential loading requires the credential buffers to live beyond this call.
            // This wrapper currently doesn't manage that lifetime.
            throw QuicError.notSupported
        }

        var config = QUIC_CREDENTIAL_CONFIG()
        config.Flags = QUIC_CREDENTIAL_FLAGS(flags.rawValue)
        
        switch type {
        case .none:
            config.Type = QUIC_CREDENTIAL_TYPE_NONE
            return try body(&config)
            
        case .certificateFile(let certPath, let keyPath):
            config.Type = QUIC_CREDENTIAL_TYPE_CERTIFICATE_FILE
            return try certPath.withCString { certPtr in
                try keyPath.withCString { keyPtr in
                    var certFile = QUIC_CERTIFICATE_FILE(
                        PrivateKeyFile: keyPtr,
                        CertificateFile: certPtr
                    )
                    // We assign the pointer of this stack-allocated struct to the config
                    // This is safe because `body` is executed within this scope
                    // But `config.CertificateFile` expects a pointer.
                    // We must pass the address of `certFile`.
                    return try withUnsafeMutablePointer(to: &certFile) { certFilePtr in
                        config.CertificateFile = certFilePtr
                        return try body(&config)
                    }
                }
            }
            
        case .certificatePkcs12(let blob, let password):
            config.Type = QUIC_CREDENTIAL_TYPE_CERTIFICATE_PKCS12
            
            return try blob.withUnsafeBytes { rawBuffer in
                return try (password ?? "").withCString { pwdPtr in
                    var pkcs12 = QUIC_CERTIFICATE_PKCS12(
                        Asn1Blob: rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                        Asn1BlobLength: UInt32(blob.count),
                        PrivateKeyPassword: password != nil ? pwdPtr : nil
                    )
                    return try withUnsafeMutablePointer(to: &pkcs12) { pkcs12Ptr in
                        config.CertificatePkcs12 = pkcs12Ptr
                        return try body(&config)
                    }
                }
            }
        }
    }
}
