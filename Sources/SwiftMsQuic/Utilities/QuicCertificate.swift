//
//  QuicCertificate.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/4/26.
//

#if canImport(Security)
import Security

/// QUIC peer certificate type.
///
/// On Darwin platforms this is an alias for `SecCertificate`, an immutable
/// Core Foundation object that is safe to pass across isolation domains.
///
/// Non-Darwin platforms are not supported by this package; see `Package.swift`
/// for the list of supported platforms.
public typealias QuicCertificate = SecCertificate
#endif
