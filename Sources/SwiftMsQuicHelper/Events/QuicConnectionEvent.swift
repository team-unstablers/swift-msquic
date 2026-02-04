//
//  QuicConnectionEvent.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic

/// The state of a datagram send operation.
public enum QuicDatagramSendState: Sendable {
    /// Unknown state.
    case unknown
    /// The datagram has been sent.
    case sent
    /// The datagram may have been lost (suspected).
    case lostSuspect
    /// The datagram was lost and discarded.
    case lostDiscarded
    /// The datagram was acknowledged by the peer.
    case acknowledged
    /// The datagram was acknowledged but may be a spurious acknowledgment.
    case acknowledgedSpurious
    /// The send operation was canceled.
    case canceled

    init(_ cState: QUIC_DATAGRAM_SEND_STATE) {
        switch cState {
        case QUIC_DATAGRAM_SEND_SENT: self = .sent
        case QUIC_DATAGRAM_SEND_LOST_SUSPECT: self = .lostSuspect
        case QUIC_DATAGRAM_SEND_LOST_DISCARDED: self = .lostDiscarded
        case QUIC_DATAGRAM_SEND_ACKNOWLEDGED: self = .acknowledged
        case QUIC_DATAGRAM_SEND_ACKNOWLEDGED_SPURIOUS: self = .acknowledgedSpurious
        case QUIC_DATAGRAM_SEND_CANCELED: self = .canceled
        default: self = .unknown
        }
    }
}

/// Events that can occur on a QUIC connection.
///
/// These events are delivered through ``QuicConnection/onEvent(_:)`` for low-level
/// event handling. Most common events are also handled by the high-level API.
public enum QuicConnectionEvent {
    /// The connection has been established.
    ///
    /// - Parameters:
    ///   - negotiatedAlpn: The ALPN protocol negotiated with the peer.
    ///   - resumption: Whether this is a resumed connection (0-RTT).
    case connected(negotiatedAlpn: String?, resumption: Bool)

    /// The connection is being shut down by the transport layer.
    ///
    /// - Parameters:
    ///   - status: The status code indicating the reason.
    ///   - errorCode: The QUIC error code.
    case shutdownInitiatedByTransport(status: QuicStatus, errorCode: UInt64)

    /// The connection is being shut down by the peer.
    ///
    /// - Parameter errorCode: The application error code from the peer.
    case shutdownInitiatedByPeer(errorCode: UInt64)

    /// The connection shutdown has completed.
    ///
    /// - Parameters:
    ///   - handshakeCompleted: Whether the TLS handshake completed before shutdown.
    ///   - peerAcknowledged: Whether the peer acknowledged the shutdown.
    ///   - appCloseInProgress: Whether the app initiated the close.
    case shutdownComplete(handshakeCompleted: Bool, peerAcknowledged: Bool, appCloseInProgress: Bool)

    /// The local address has changed (e.g., NAT rebinding).
    case localAddressChanged(address: QuicAddress)

    /// The peer's address has changed.
    case peerAddressChanged(address: QuicAddress)

    /// The peer has started a new stream.
    ///
    /// - Parameters:
    ///   - stream: The raw stream handle.
    ///   - flags: Flags indicating stream properties.
    case peerStreamStarted(stream: HQUIC, flags: QuicStreamOpenFlags)

    /// Additional streams are now available.
    ///
    /// - Parameters:
    ///   - bidirectional: Number of bidirectional streams available.
    ///   - unidirectional: Number of unidirectional streams available.
    case streamsAvailable(bidirectional: UInt16, unidirectional: UInt16)

    /// The peer needs more streams to be opened.
    ///
    /// - Parameter bidirectional: Whether bidirectional streams are needed.
    case peerNeedsStreams(bidirectional: Bool)

    /// The ideal processor for this connection has changed.
    case idealProcessorChanged(processor: UInt16, partitionIndex: UInt16)

    /// The datagram send state has changed.
    case datagramStateChanged(sendEnabled: Bool, maxSendLength: UInt16)

    /// A datagram was received from the peer.
    case datagramReceived(buffer: QuicBuffer, flags: QuicReceiveFlags)

    /// The state of a datagram send has changed.
    case datagramSendStateChanged(state: QuicDatagramSendState, context: UnsafeMutableRawPointer?)

    /// The connection was resumed from a previous session.
    case resumed(resumptionState: Data?)

    /// A resumption ticket was received from the server.
    case resumptionTicketReceived(ticket: Data)

    /// The peer's certificate was received.
    ///
    /// This event is delivered when ``QuicCredentialFlags/indicateCertificateReceived`` is set.
    /// When ``QuicCredentialFlags/deferCertificateValidation`` is also set, the application
    /// can perform custom certificate validation and return the appropriate status.
    ///
    /// - Parameters:
    ///   - certificate: Platform-specific peer certificate handle. Valid only during the callback.
    ///   - chain: Platform-specific certificate chain handle. Valid only during the callback.
    ///   - deferredErrorFlags: Bit flags indicating validation errors (Schannel/Windows only, zero on macOS/iOS).
    ///   - deferredStatus: The validation error status. Check this on macOS/iOS instead of error flags.
    ///
    /// - Important: The `certificate` and `chain` pointers are only valid during the event callback.
    ///   If you need to retain the certificate data, copy it before the callback returns.
    case peerCertificateReceived(
        certificate: UnsafeMutableRawPointer?,
        chain: UnsafeMutableRawPointer?,
        deferredErrorFlags: QuicCertificateValidationFlags,
        deferredStatus: QuicStatus
    )

    /// An unknown event type was received.
    case unknown
}
