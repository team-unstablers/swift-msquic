//
//  QuicError.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic

/// Errors that can occur during QUIC operations.
///
/// `QuicError` provides Swift-friendly error cases for common QUIC failures.
/// It can be initialized from a ``QuicStatus`` to convert MsQuic status codes
/// into meaningful error types.
public enum QuicError: Error, Hashable, Sendable {
    /// MsQuic library was not initialized.
    case notInitialized

    /// An invalid parameter was provided.
    case invalidParameter

    /// The operation is not valid in the current state.
    case invalidState

    /// Memory allocation failed.
    case outOfMemory

    /// The connection was refused by the peer.
    case connectionRefused

    /// The connection timed out.
    case connectionTimeout

    /// The TLS handshake failed.
    case handshakeFailure

    /// The operation was aborted.
    case aborted

    /// The address is already in use.
    case addressInUse

    /// The peer is unreachable.
    case unreachable

    /// The connection was closed due to idle timeout.
    case connectionIdle

    /// An internal error occurred.
    case internalError

    /// The server is too busy to accept the connection.
    case serverBusy

    /// A QUIC protocol error occurred.
    case protocolError

    /// The stream limit has been reached.
    case streamLimitReached

    /// The operation is not supported.
    case notSupported

    /// A TLS alert was received.
    ///
    /// - Parameter alert: The TLS alert code.
    case tlsError(alert: Int32)

    /// A certificate error occurred.
    ///
    /// - Parameter type: The type of certificate error.
    case certError(type: CertErrorType)

    /// An unknown error occurred.
    ///
    /// - Parameter status: The raw status code.
    case unknown(status: QuicStatus)

    /// Types of certificate errors.
    public enum CertErrorType: Hashable, Sendable {
        /// The certificate has expired.
        case expired
        /// The certificate has an untrusted root.
        case untrustedRoot
        /// No certificate was provided.
        case noCert
        /// An unknown certificate error.
        case unknown(Int32)
    }

    /// Creates an error from a ``QuicStatus``.
    ///
    /// - Parameter status: The status code to convert.
    public init(status: QuicStatus) {
        switch status {
        case .invalidParameter:     self = .invalidParameter
        case .invalidState:         self = .invalidState
        case .outOfMemory:          self = .outOfMemory
        case .connectionRefused:    self = .connectionRefused
        case .connectionTimeout:    self = .connectionTimeout
        case .handshakeFailure:     self = .handshakeFailure
        case .aborted:              self = .aborted
        case .addressInUse:         self = .addressInUse
        case .unreachable:          self = .unreachable
        case .connectionIdle:       self = .connectionIdle
        case .internalError:        self = .internalError
        case .protocolError:        self = .protocolError
        case .streamLimitReached:   self = .streamLimitReached
        case .notSupported:         self = .notSupported
            
        default:
            // Check for TLS Errors
            let raw = status.rawValue
            if raw >= QuicStatus.tlsErrorBase && raw < QuicStatus.certErrorBase {
                self = .tlsError(alert: Int32(bitPattern: raw) - QuicStatus.tlsErrorBase)
                return
            }
            
            // Check for Cert Errors
            if raw >= QuicStatus.certErrorBase {
                let certErr = Int32(bitPattern: raw) - QuicStatus.certErrorBase
                switch status {
                case .certExpired:          self = .certError(type: .expired)
                case .certUntrustedRoot:    self = .certError(type: .untrustedRoot)
                case .certNoCert:           self = .certError(type: .noCert)
                default:                    self = .certError(type: .unknown(certErr))
                }
                return
            }

            self = .unknown(status: status)
        }
    }
}
