//
//  QuicError.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic

public enum QuicError: Error, Hashable, Sendable {
    case notInitialized
    case invalidParameter
    case invalidState
    case outOfMemory
    case connectionRefused
    case connectionTimeout
    case handshakeFailure
    case aborted
    case addressInUse
    case unreachable
    case connectionIdle
    case internalError
    case serverBusy
    case protocolError
    case streamLimitReached
    
    case tlsError(alert: Int32)
    case certError(type: CertErrorType)
    
    case unknown(status: QuicStatus)

    public enum CertErrorType: Hashable, Sendable {
        case expired
        case untrustedRoot
        case noCert
        case unknown(Int32)
    }

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
