//
//  QuicCertificate.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/4/26.
//

import Foundation

#if canImport(Security)
import Security

/// QUIC peer certificate type.
///
/// On Darwin platforms this is an alias for `SecCertificate`, an immutable
/// Core Foundation object that is safe to pass across isolation domains.
public typealias QuicCertificate = SecCertificate
#else

/// QUIC peer certificate type for non-Darwin platforms.
///
/// Wraps a DER-encoded X.509 certificate extracted from the OpenSSL X509
/// structure provided by MsQuic during the ``QuicConnectionEvent/peerCertificateReceived``
/// event.
public struct QuicCertificate: Sendable {
    /// The DER-encoded X.509 certificate data.
    public let derData: Data

    public init(derData: Data) {
        self.derData = derData
    }
}
#endif
