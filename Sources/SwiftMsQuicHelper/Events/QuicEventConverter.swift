//
//  QuicEventConverter.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import SwiftMsQuic

internal enum QuicEventConverter {
    static func convert(_ event: QUIC_LISTENER_EVENT) -> QuicListenerEvent {
        switch event.Type {
        case QUIC_LISTENER_EVENT_NEW_CONNECTION:
            let info = event.NEW_CONNECTION.Info.pointee
            
            let serverName = info.ServerName.map { String(cString: $0) }
            
            var negotiatedAlpn: String? = nil
            if let alpn = info.NegotiatedAlpn, info.NegotiatedAlpnLength > 0 {
                negotiatedAlpn = String(bytes: UnsafeBufferPointer(start: alpn, count: Int(info.NegotiatedAlpnLength)), encoding: .utf8)
            }
            
            let localAddress = QuicAddress(info.LocalAddress.pointee)
            let remoteAddress = QuicAddress(info.RemoteAddress.pointee)
            
            return .newConnection(info: .init(
                connection: event.NEW_CONNECTION.Connection,
                serverName: serverName,
                negotiatedAlpn: negotiatedAlpn,
                localAddress: localAddress,
                remoteAddress: remoteAddress
            ))
            
        case QUIC_LISTENER_EVENT_STOP_COMPLETE:
            return .stopComplete
            
        default:
            return .unknown
        }
    }
    
    static func convert(_ event: QUIC_CONNECTION_EVENT) -> QuicConnectionEvent {
        switch event.Type {
        case QUIC_CONNECTION_EVENT_CONNECTED:
            let connected = event.CONNECTED
            var negotiatedAlpn: String? = nil
            if let alpn = connected.NegotiatedAlpn, connected.NegotiatedAlpnLength > 0 {
                negotiatedAlpn = String(bytes: UnsafeBufferPointer(start: alpn, count: Int(connected.NegotiatedAlpnLength)), encoding: .utf8)
            }
            return .connected(negotiatedAlpn: negotiatedAlpn, resumption: connected.SessionResumed != 0)
            
        case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_TRANSPORT:
            let shutdown = event.SHUTDOWN_INITIATED_BY_TRANSPORT
            return .shutdownInitiatedByTransport(status: QuicStatus(shutdown.Status), errorCode: shutdown.ErrorCode)
            
        case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_PEER:
            return .shutdownInitiatedByPeer(errorCode: event.SHUTDOWN_INITIATED_BY_PEER.ErrorCode)
            
        case QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE:
            let complete = event.SHUTDOWN_COMPLETE
            return .shutdownComplete(
                handshakeCompleted: complete.HandshakeCompleted != 0,
                peerAcknowledged: complete.PeerAcknowledgedShutdown != 0,
                appCloseInProgress: complete.AppCloseInProgress != 0
            )
            
        case QUIC_CONNECTION_EVENT_LOCAL_ADDRESS_CHANGED:
            return .localAddressChanged(address: QuicAddress(event.LOCAL_ADDRESS_CHANGED.Address.pointee))
            
        case QUIC_CONNECTION_EVENT_PEER_ADDRESS_CHANGED:
            return .peerAddressChanged(address: QuicAddress(event.PEER_ADDRESS_CHANGED.Address.pointee))
            
        case QUIC_CONNECTION_EVENT_PEER_STREAM_STARTED:
            let started = event.PEER_STREAM_STARTED
            return .peerStreamStarted(stream: started.Stream, flags: QuicStreamOpenFlags(rawValue: UInt32(started.Flags.rawValue)))
            
        case QUIC_CONNECTION_EVENT_STREAMS_AVAILABLE:
            let available = event.STREAMS_AVAILABLE
            return .streamsAvailable(bidirectional: available.BidirectionalCount, unidirectional: available.UnidirectionalCount)
            
        case QUIC_CONNECTION_EVENT_PEER_NEEDS_STREAMS:
            return .peerNeedsStreams(bidirectional: event.PEER_NEEDS_STREAMS.Bidirectional != 0)
            
        case QUIC_CONNECTION_EVENT_IDEAL_PROCESSOR_CHANGED:
            let ideal = event.IDEAL_PROCESSOR_CHANGED
            return .idealProcessorChanged(processor: ideal.IdealProcessor, partitionIndex: ideal.PartitionIndex)
            
        case QUIC_CONNECTION_EVENT_DATAGRAM_STATE_CHANGED:
            let state = event.DATAGRAM_STATE_CHANGED
            return .datagramStateChanged(sendEnabled: state.SendEnabled != 0, maxSendLength: state.MaxSendLength)
            
        case QUIC_CONNECTION_EVENT_DATAGRAM_RECEIVED:
            let recv = event.DATAGRAM_RECEIVED
            let data = Data(bytes: recv.Buffer.pointee.Buffer, count: Int(recv.Buffer.pointee.Length))
            return .datagramReceived(buffer: QuicBuffer(data), flags: QuicReceiveFlags(rawValue: UInt32(recv.Flags.rawValue)))
            
        case QUIC_CONNECTION_EVENT_DATAGRAM_SEND_STATE_CHANGED:
            let state = event.DATAGRAM_SEND_STATE_CHANGED
            return .datagramSendStateChanged(state: QuicDatagramSendState(state.State), context: state.ClientContext)
            
        case QUIC_CONNECTION_EVENT_RESUMED:
            let resumed = event.RESUMED
            var data: Data? = nil
            if let ptr = resumed.ResumptionState, resumed.ResumptionStateLength > 0 {
                data = Data(bytes: ptr, count: Int(resumed.ResumptionStateLength))
            }
            return .resumed(resumptionState: data)
            
        case QUIC_CONNECTION_EVENT_RESUMPTION_TICKET_RECEIVED:
            let ticket = event.RESUMPTION_TICKET_RECEIVED
            let data = Data(bytes: ticket.ResumptionTicket, count: Int(ticket.ResumptionTicketLength))
            return .resumptionTicketReceived(ticket: data)
            
        case QUIC_CONNECTION_EVENT_PEER_CERTIFICATE_RECEIVED:
            let cert = event.PEER_CERTIFICATE_RECEIVED
            return .peerCertificateReceived(certificate: cert.Certificate, chain: cert.Chain)
            
        default:
            return .unknown
        }
    }
    
    static func convert(_ event: QUIC_STREAM_EVENT) -> QuicStreamEvent {
        switch event.Type {
        case QUIC_STREAM_EVENT_START_COMPLETE:
            let start = event.START_COMPLETE
            return .startComplete(status: QuicStatus(start.Status), id: start.ID, peerAccepted: start.PeerAccepted != 0)
            
        case QUIC_STREAM_EVENT_RECEIVE:
            let receive = event.RECEIVE
            var data = Data()
            if receive.TotalBufferLength > 0, let buffers = receive.Buffers {
                // Pre-allocate to avoid reallocations
                data.reserveCapacity(Int(receive.TotalBufferLength))
                for i in 0..<Int(receive.BufferCount) {
                    let buf = buffers[i]
                    if let ptr = buf.Buffer {
                        data.append(ptr, count: Int(buf.Length))
                    }
                }
            }
            return .receive(
                data: data,
                flags: QuicReceiveFlags(rawValue: UInt32(receive.Flags.rawValue)),
                absoluteOffset: receive.AbsoluteOffset,
                totalBufferLength: receive.TotalBufferLength
            )
            
        case QUIC_STREAM_EVENT_SEND_COMPLETE:
            let send = event.SEND_COMPLETE
            return .sendComplete(canceled: send.Canceled != 0, context: send.ClientContext)
            
        case QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN:
            return .peerSendShutdown
            
        case QUIC_STREAM_EVENT_PEER_SEND_ABORTED:
            return .peerSendAborted(errorCode: event.PEER_SEND_ABORTED.ErrorCode)
            
        case QUIC_STREAM_EVENT_PEER_RECEIVE_ABORTED:
            return .peerReceiveAborted(errorCode: event.PEER_RECEIVE_ABORTED.ErrorCode)
            
        case QUIC_STREAM_EVENT_SEND_SHUTDOWN_COMPLETE:
            return .sendShutdownComplete(graceful: event.SEND_SHUTDOWN_COMPLETE.Graceful != 0)
            
        case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE:
            let complete = event.SHUTDOWN_COMPLETE
            return .shutdownComplete(
                connectionShutdown: complete.ConnectionShutdown != 0,
                appCloseInProgress: complete.AppCloseInProgress != 0,
                connectionShutdownByApp: complete.ConnectionShutdownByApp != 0,
                connectionClosedRemotely: complete.ConnectionClosedRemotely != 0,
                connectionErrorCode: complete.ConnectionErrorCode,
                connectionCloseStatus: QuicStatus(complete.ConnectionCloseStatus)
            )
            
        case QUIC_STREAM_EVENT_IDEAL_SEND_BUFFER_SIZE:
            return .idealSendBufferSize(byteCount: event.IDEAL_SEND_BUFFER_SIZE.ByteCount)
            
        case QUIC_STREAM_EVENT_PEER_ACCEPTED:
            return .peerAccepted
            
        case QUIC_STREAM_EVENT_CANCEL_ON_LOSS:
            return .cancelOnLoss(errorCode: event.CANCEL_ON_LOSS.ErrorCode)
            
        default:
            return .unknown
        }
    }
}
