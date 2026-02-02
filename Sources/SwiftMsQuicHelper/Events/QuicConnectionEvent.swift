//
//  QuicConnectionEvent.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import SwiftMsQuic

public enum QuicDatagramSendState: Sendable {
    case unknown
    case sent
    case lostSuspect
    case lostDiscarded
    case acknowledged
    case acknowledgedSpurious
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

public enum QuicConnectionEvent {
    case connected(negotiatedAlpn: String?, resumption: Bool)
    case shutdownInitiatedByTransport(status: QuicStatus, errorCode: UInt64)
    case shutdownInitiatedByPeer(errorCode: UInt64)
    case shutdownComplete(handshakeCompleted: Bool, peerAcknowledged: Bool, appCloseInProgress: Bool)
    case localAddressChanged(address: QuicAddress)
    case peerAddressChanged(address: QuicAddress)
    case peerStreamStarted(stream: HQUIC, flags: QuicStreamOpenFlags)
    case streamsAvailable(bidirectional: UInt16, unidirectional: UInt16)
    case peerNeedsStreams(bidirectional: Bool)
    case idealProcessorChanged(processor: UInt16, partitionIndex: UInt16)
    case datagramStateChanged(sendEnabled: Bool, maxSendLength: UInt16)
    case datagramReceived(buffer: QuicBuffer, flags: QuicReceiveFlags)
    case datagramSendStateChanged(state: QuicDatagramSendState, context: UnsafeMutableRawPointer?)
    case resumed(resumptionState: Data?)
    case resumptionTicketReceived(ticket: Data)
    case peerCertificateReceived(certificate: UnsafeMutableRawPointer?, chain: UnsafeMutableRawPointer?)
    
    case unknown
}
