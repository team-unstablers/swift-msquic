//
//  QuicFlags.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic

/// Flags for opening a QUIC stream.
///
/// These flags control the behavior of a stream when it's opened.
public struct QuicStreamOpenFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// No special flags.
    public static let none = QuicStreamOpenFlags([])

    /// Open a unidirectional stream (send only).
    public static let unidirectional = QuicStreamOpenFlags(rawValue: UInt32(QUIC_STREAM_OPEN_FLAG_UNIDIRECTIONAL.rawValue))

    /// Allow sending data before the connection handshake completes (0-RTT).
    public static let zeroRtt = QuicStreamOpenFlags(rawValue: UInt32(QUIC_STREAM_OPEN_FLAG_0_RTT.rawValue))

    /// Delay ID/flow control updates.
    public static let delayIdFcUpdates = QuicStreamOpenFlags(rawValue: UInt32(QUIC_STREAM_OPEN_FLAG_DELAY_ID_FC_UPDATES.rawValue))
}

/// Flags for starting a QUIC stream.
///
/// These flags control the behavior when starting a stream.
public struct QuicStreamStartFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// No special flags.
    public static let none = QuicStreamStartFlags([])

    /// Start the stream immediately without waiting.
    public static let immediate = QuicStreamStartFlags(rawValue: UInt32(QUIC_STREAM_START_FLAG_IMMEDIATE.rawValue))

    /// Fail immediately if the stream cannot be started due to flow control.
    public static let failBlocked = QuicStreamStartFlags(rawValue: UInt32(QUIC_STREAM_START_FLAG_FAIL_BLOCKED.rawValue))

    /// Shutdown the stream if start fails.
    public static let shutdownOnFail = QuicStreamStartFlags(rawValue: UInt32(QUIC_STREAM_START_FLAG_SHUTDOWN_ON_FAIL.rawValue))

    /// Receive an event when the peer accepts the stream.
    public static let indicatePeerAccept = QuicStreamStartFlags(rawValue: UInt32(QUIC_STREAM_START_FLAG_INDICATE_PEER_ACCEPT.rawValue))
}

/// Flags indicating properties of received data.
///
/// These flags are provided with received data to indicate special conditions.
public struct QuicReceiveFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// No special flags.
    public static let none = QuicReceiveFlags([])

    /// Data was received via 0-RTT (early data).
    public static let zeroRtt = QuicReceiveFlags(rawValue: UInt32(QUIC_RECEIVE_FLAG_0_RTT.rawValue))

    /// This is the final data on the stream (FIN received).
    public static let fin = QuicReceiveFlags(rawValue: UInt32(QUIC_RECEIVE_FLAG_FIN.rawValue))
}

/// Flags for sending data on a stream.
///
/// These flags control the behavior of a send operation.
public struct QuicSendFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// No special flags.
    public static let none = QuicSendFlags([])

    /// Allow sending the data via 0-RTT (early data).
    public static let allowZeroRtt = QuicSendFlags(rawValue: UInt32(QUIC_SEND_FLAG_ALLOW_0_RTT.rawValue))

    /// Start the stream with this send operation.
    public static let start = QuicSendFlags(rawValue: UInt32(QUIC_SEND_FLAG_START.rawValue))

    /// Indicate this is the final send on the stream (send FIN).
    ///
    /// After using this flag, no more data can be sent on the stream.
    public static let fin = QuicSendFlags(rawValue: UInt32(QUIC_SEND_FLAG_FIN.rawValue))

    /// Send as a high-priority datagram.
    public static let dgramPriority = QuicSendFlags(rawValue: UInt32(QUIC_SEND_FLAG_DGRAM_PRIORITY.rawValue))

    /// Delay sending until explicitly flushed.
    public static let delaySend = QuicSendFlags(rawValue: UInt32(QUIC_SEND_FLAG_DELAY_SEND.rawValue))
}

public struct QuicStreamShutdownFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// **Invalid** option.
    public static let none = QuicStreamShutdownFlags([])
    
    public static let graceful = QuicStreamShutdownFlags(rawValue: UInt32(QUIC_STREAM_SHUTDOWN_FLAG_GRACEFUL.rawValue))

    /// Indicates the app is gracefully shutting down the stream in the send direction.
    public static let abortSend = QuicStreamShutdownFlags(rawValue: UInt32(QUIC_STREAM_SHUTDOWN_FLAG_ABORT_SEND.rawValue))

    /// Indicates the app is abortively shutting down the stream in the receive direction.
    public static let abortReceive = QuicStreamShutdownFlags(rawValue: UInt32(QUIC_STREAM_SHUTDOWN_FLAG_ABORT_RECEIVE.rawValue))

    public static let abort = QuicStreamShutdownFlags([.abortSend, .abortReceive])
    
    // Indicates the app does not want to wait for the acknowledgment of the shutdown before getting the `QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE` event. Only allowed for abortive shutdowns.
    public static let immediate = QuicStreamShutdownFlags(rawValue: UInt32(QUIC_STREAM_SHUTDOWN_FLAG_IMMEDIATE.rawValue))
    
    // Indicates that the stream shutdown should be processed inmediately inline. This in only applicable for calls made within callbacks.
    // WARNING: It can cause reentrant callbacks!
    public static let inline = QuicStreamShutdownFlags(rawValue: UInt32(QUIC_STREAM_SHUTDOWN_FLAG_INLINE.rawValue))
}
