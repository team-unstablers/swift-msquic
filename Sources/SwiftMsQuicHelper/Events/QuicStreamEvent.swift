//
//  QuicStreamEvent.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic

/// Events that can occur on a QUIC stream.
///
/// These events are delivered internally and used to manage stream state.
/// Most users should use the high-level ``QuicStream`` API instead of
/// handling these events directly.
public enum QuicStreamEvent {
    /// The stream start operation has completed.
    ///
    /// - Parameters:
    ///   - status: The status of the start operation.
    ///   - id: The stream ID assigned by the transport.
    ///   - peerAccepted: Whether the peer has accepted the stream.
    case startComplete(status: QuicStatus, id: UInt64, peerAccepted: Bool)

    /// Data was received on the stream.
    ///
    /// The data is copied from the underlying buffers and is safe to use
    /// after the event handler returns.
    ///
    /// - Parameters:
    ///   - data: The received data.
    ///   - flags: Flags indicating properties of the received data.
    ///   - absoluteOffset: The byte offset from the start of the stream.
    ///   - totalBufferLength: The total length of the received buffer.
    case receive(data: Data, flags: QuicReceiveFlags, absoluteOffset: UInt64, totalBufferLength: UInt64)

    /// A send operation has completed.
    ///
    /// - Parameters:
    ///   - canceled: Whether the send was canceled.
    ///   - context: The user-provided context from the send call.
    case sendComplete(canceled: Bool, context: UnsafeMutableRawPointer?)

    /// The peer has finished sending data (FIN received).
    case peerSendShutdown

    /// The peer has aborted the send direction.
    ///
    /// - Parameter errorCode: The error code from the peer.
    case peerSendAborted(errorCode: UInt64)

    /// The peer has aborted the receive direction.
    ///
    /// - Parameter errorCode: The error code from the peer.
    case peerReceiveAborted(errorCode: UInt64)

    /// The send shutdown has completed.
    ///
    /// - Parameter graceful: Whether the shutdown was graceful.
    case sendShutdownComplete(graceful: Bool)

    /// The stream has been fully shut down.
    case shutdownComplete(connectionShutdown: Bool, appCloseInProgress: Bool, connectionShutdownByApp: Bool, connectionClosedRemotely: Bool, connectionErrorCode: UInt64, connectionCloseStatus: QuicStatus)

    /// The ideal send buffer size has been determined.
    ///
    /// - Parameter byteCount: The recommended number of bytes to buffer.
    case idealSendBufferSize(byteCount: UInt64)

    /// The peer has accepted the stream.
    case peerAccepted

    /// The send should be canceled on loss.
    ///
    /// - Parameter errorCode: The error code to use.
    case cancelOnLoss(errorCode: UInt64)

    /// An unknown event type was received.
    case unknown
}
