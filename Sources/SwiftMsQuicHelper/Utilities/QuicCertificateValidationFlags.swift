//
//  QuicCertificateValidationFlags.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/4/26.
//

import Foundation

/// Flags indicating certificate validation errors when using deferred validation.
///
/// These flags are primarily used on Windows with Schannel. On macOS/iOS,
/// these flags will typically be zero, and you should check the deferred status instead.
///
/// - Note: Multiple flags may be set simultaneously to indicate multiple validation errors.
///
/// ## Platform Differences
///
/// | Platform | Error Flags | Deferred Status |
/// |----------|-------------|-----------------|
/// | Windows (Schannel) | Populated | Populated |
/// | macOS/iOS | Always zero | Populated |
///
/// ## Topics
///
/// ### Common Validation Errors
/// - ``isNotTimeValid``
/// - ``isRevoked``
/// - ``isUntrustedRoot``
///
/// ### Chain Validation Errors
/// - ``isPartialChain``
/// - ``invalidBasicConstraints``
public struct QuicCertificateValidationFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// No validation errors.
    public static let none = QuicCertificateValidationFlags([])

    // MARK: - Time Validity

    /// The certificate's time validity is invalid (expired or not yet valid).
    public static let isNotTimeValid = QuicCertificateValidationFlags(rawValue: 0x00000001)

    // MARK: - Revocation

    /// The certificate has been revoked.
    public static let isRevoked = QuicCertificateValidationFlags(rawValue: 0x00000004)

    /// The revocation status is unknown (OCSP/CRL check failed).
    public static let revocationStatusUnknown = QuicCertificateValidationFlags(rawValue: 0x00000040)

    // MARK: - Signature & Usage

    /// The certificate's signature is not valid.
    public static let isNotSignatureValid = QuicCertificateValidationFlags(rawValue: 0x00000008)

    /// The certificate is not valid for the requested usage.
    public static let isNotValidForUsage = QuicCertificateValidationFlags(rawValue: 0x00000010)

    // MARK: - Trust Chain

    /// The certificate chain terminates in an untrusted root.
    public static let isUntrustedRoot = QuicCertificateValidationFlags(rawValue: 0x00000020)

    /// A certificate in the chain is a cyclic reference.
    public static let isCyclic = QuicCertificateValidationFlags(rawValue: 0x00000080)

    /// The certificate chain is a partial chain (missing intermediate or root).
    public static let isPartialChain = QuicCertificateValidationFlags(rawValue: 0x00010000)

    // MARK: - Constraints

    /// A certificate in the chain has an invalid extension.
    public static let invalidExtension = QuicCertificateValidationFlags(rawValue: 0x00000100)

    /// A certificate in the chain has an invalid policy constraint.
    public static let invalidPolicyConstraints = QuicCertificateValidationFlags(rawValue: 0x00000200)

    /// A certificate in the chain has an invalid basic constraint.
    public static let invalidBasicConstraints = QuicCertificateValidationFlags(rawValue: 0x00000400)

    /// A certificate in the chain has an invalid name constraint.
    public static let invalidNameConstraints = QuicCertificateValidationFlags(rawValue: 0x00000800)

    /// The certificate chain contains a certificate without a supported name constraint.
    public static let hasNotSupportedNameConstraint = QuicCertificateValidationFlags(rawValue: 0x00001000)

    /// A certificate in the chain has an undefined name constraint.
    public static let hasNotDefinedNameConstraint = QuicCertificateValidationFlags(rawValue: 0x00002000)

    /// A certificate in the chain has an unsupported name constraint.
    public static let hasNotPermittedNameConstraint = QuicCertificateValidationFlags(rawValue: 0x00004000)

    /// A certificate in the chain has an excluded name constraint.
    public static let hasExcludedNameConstraint = QuicCertificateValidationFlags(rawValue: 0x00008000)

    /// Returns true if any validation error flag is set.
    public var hasErrors: Bool { rawValue != 0 }
}
