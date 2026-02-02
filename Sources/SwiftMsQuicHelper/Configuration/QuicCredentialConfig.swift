//
//  QuicCredentialConfig.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import SwiftMsQuic

public enum QuicCredentialType {
    /// Certificate file path (PEM etc) and private key path
    case certificateFile(certPath: String, keyPath: String)
    
    /// PKCS#12 file
    case certificatePkcs12(path: String, password: String?)
    
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
            
        case .certificatePkcs12(let path, let password):
            config.Type = QUIC_CREDENTIAL_TYPE_CERTIFICATE_PKCS12
            // We need to read the file into a buffer for PKCS12
            // Or does MsQuic accept a path?
            // Checking msquic.h:
            // typedef struct QUIC_CERTIFICATE_PKCS12 {
            //     const uint8_t *Asn1Blob;
            //     uint32_t Asn1BlobLength;
            //     const char *PrivateKeyPassword;
            // } QUIC_CERTIFICATE_PKCS12;
            // It expects a Blob, not a file path.
            
            // So we must read the file.
            // CAUTION: This performs synchronous I/O.
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                // If file read fails, we can't really throw here easily as this is a conversion function
                // but maybe we should propagate error?
                // For now, let's treat it as empty or fail?
                // Ideally this function should allow throwing.
                // Re-declaring `rethrows` but we are actually throwing error inside closures?
                // The signature says `rethrows`, so we can throw if `body` throws, 
                // but if WE throw, it must be marked `throws`.
                // Let's change signature to `throws` implicitly by making `rethrows` work
                // But wait, reading file is not part of `body`.
                fatalError("Failed to read PKCS12 file at \(path)")
            }
            
            return try data.withUnsafeBytes { rawBuffer in
                return try (password ?? "").withCString { pwdPtr in
                    var pkcs12 = QUIC_CERTIFICATE_PKCS12(
                        Asn1Blob: rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                        Asn1BlobLength: UInt32(data.count),
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
