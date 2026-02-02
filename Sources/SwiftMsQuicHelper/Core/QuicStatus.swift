//
//  QuicStatus.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import SwiftMsQuic
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct QuicStatus: RawRepresentable, Hashable, Equatable, Sendable {
    // unsigned int
    public var rawValue: QuicStatusRawValue
    
    public init(rawValue: QuicStatusRawValue) {
        self.rawValue = rawValue
    }
    
    static func defineStatus(_ x: Int32) -> Self {
        Self(rawValue: QuicStatusRawValue(bitPattern: x))
    }
}

public extension QuicStatus {
    var succeeded: Bool {
        // static_cast<int>(X) > 0
        Int32(bitPattern: rawValue) > 0
    }
    
    var failed: Bool {
        Int32(bitPattern: rawValue) <= 0
    }
    
    func throwIfFailed() throws {
        if failed {
            throw QuicError(status: self)
        }
    }
}

public extension QuicStatus {
    init(_ rawValue: QuicStatusRawValue) {
        self.init(rawValue: rawValue)
    }
    
    static func == (lhs: Self, rhs: QuicStatusRawValue) -> Bool {
        return lhs.rawValue == rhs
    }
    
    static func == (lhs: QuicStatusRawValue, rhs: Self) -> Bool {
        return lhs == rhs.rawValue
    }
}


public extension QuicStatus {
    static let errorBase: Int32 = 200_000_000
    static let tlsErrorBase: Int32 = 256 + Self.errorBase
    static let certErrorBase: Int32 = 512 + Self.errorBase

    static let success: Self = .defineStatus(0)
    static let pending: Self = .defineStatus(-2)
    static let `continue`: Self = .defineStatus(-1)
    static let outOfMemory: Self = .defineStatus(Int32(ENOMEM))
    static let invalidParameter: Self = .defineStatus(Int32(EINVAL))
    static let invalidState: Self = .defineStatus(Int32(EPERM))
    static let notSupported: Self = .defineStatus(Int32(EOPNOTSUPP))
    static let notFound: Self = .defineStatus(Int32(ENOENT))
    static let fileNotFound: Self = .notFound
    static let bufferTooSmall: Self = .defineStatus(Int32(EOVERFLOW))
    static let handshakeFailure: Self = .defineStatus(Int32(ECONNABORTED))
    static let aborted: Self = .defineStatus(Int32(ECANCELED))
    static let addressInUse: Self = .defineStatus(Int32(EADDRINUSE))
    static let invalidAddress: Self = .defineStatus(Int32(EAFNOSUPPORT))
    static let connectionTimeout: Self = .defineStatus(Int32(ETIMEDOUT))
    static let connectionIdle: Self = .defineStatus(Int32(ETIME))
    static let internalError: Self = .defineStatus(Int32(EIO))
    static let connectionRefused: Self = .defineStatus(Int32(ECONNREFUSED))
    static let protocolError: Self = .defineStatus(Int32(EPROTO))
    static let versionNegotiationError: Self = .defineStatus(Int32(EPROTONOSUPPORT))
    static let unreachable: Self = .defineStatus(Int32(EHOSTUNREACH))
    static let tlsError: Self = .defineStatus(Int32(ENOKEY))
    static let userCanceled: Self = .defineStatus(Int32(EOWNERDEAD))
    static let alpnNegotiationFailure: Self = .defineStatus(Int32(ENOPROTOOPT))
    static let streamLimitReached: Self = .defineStatus(Int32(ESTRPIPE))
    static let alpnInUse: Self = .defineStatus(Int32(EPROTOTYPE))
    static let addressNotAvailable: Self = .defineStatus(Int32(EADDRNOTAVAIL))

    static func tlsAlert(_ alert: Int32) -> Self {
        .defineStatus((alert & 0xff) + Self.tlsErrorBase)
    }

    static let closeNotify: Self = .tlsAlert(0)
    static let badCertificate: Self = .tlsAlert(42)
    static let unsupportedCertificate: Self = .tlsAlert(43)
    static let revokedCertificate: Self = .tlsAlert(44)
    static let expiredCertificate: Self = .tlsAlert(45)
    static let unknownCertificate: Self = .tlsAlert(46)
    static let requiredCertificate: Self = .tlsAlert(116)

    static func certError(_ value: Int32) -> Self {
        .defineStatus(value + Self.certErrorBase)
    }

    static let certExpired: Self = .certError(1)
    static let certUntrustedRoot: Self = .certError(2)
    static let certNoCert: Self = .certError(3)
}
