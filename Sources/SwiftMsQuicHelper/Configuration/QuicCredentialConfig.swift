//
//  QuicCredentialConfig.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic

public enum QuicCredentialType {
    /// Certificate file path (PEM etc) and private key path
    case certificateFile(certPath: String, keyPath: String)
    
    /// PKCS#12 blob (ASN.1)
    case certificatePkcs12(blob: Data, password: String?)
    
    /// No certificate (Client mode, or when using system store implicitly if supported later)
    case none
}

public struct QuicCredentialFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
    
    public static let none = QuicCredentialFlags([])
    public static let client = QuicCredentialFlags(rawValue: UInt32(QUIC_CREDENTIAL_FLAG_CLIENT.rawValue))
    public static let loadAsynchronous = QuicCredentialFlags(rawValue: UInt32(QUIC_CREDENTIAL_FLAG_LOAD_ASYNCHRONOUS.rawValue))
    public static let noCertificateValidation = QuicCredentialFlags(rawValue: UInt32(QUIC_CREDENTIAL_FLAG_NO_CERTIFICATE_VALIDATION.rawValue))
    public static let indicateCertificateReceived = QuicCredentialFlags(rawValue: UInt32(QUIC_CREDENTIAL_FLAG_INDICATE_CERTIFICATE_RECEIVED.rawValue))
    public static let deferCertificateValidation = QuicCredentialFlags(rawValue: UInt32(QUIC_CREDENTIAL_FLAG_DEFER_CERTIFICATE_VALIDATION.rawValue))
    public static let requireClientAuthentication = QuicCredentialFlags(rawValue: UInt32(QUIC_CREDENTIAL_FLAG_REQUIRE_CLIENT_AUTHENTICATION.rawValue))
}

public struct QuicCredentialConfig {
    public let type: QuicCredentialType
    public let flags: QuicCredentialFlags
    
    public init(type: QuicCredentialType, flags: QuicCredentialFlags = []) {
        self.type = type
        self.flags = flags
    }
    
    internal func withUnsafeCredentialConfig<T>(_ body: (UnsafePointer<QUIC_CREDENTIAL_CONFIG>) throws -> T) rethrows -> T {
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
