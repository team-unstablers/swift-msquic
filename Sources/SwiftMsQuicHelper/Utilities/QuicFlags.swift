//
//  QuicFlags.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import SwiftMsQuic

public struct QuicStreamOpenFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    
    public static let none = QuicStreamOpenFlags([])
    public static let unidirectional = QuicStreamOpenFlags(rawValue: UInt32(QUIC_STREAM_OPEN_FLAG_UNIDIRECTIONAL.rawValue))
    public static let zeroRtt = QuicStreamOpenFlags(rawValue: UInt32(QUIC_STREAM_OPEN_FLAG_0_RTT.rawValue))
    public static let delayIdFcUpdates = QuicStreamOpenFlags(rawValue: UInt32(QUIC_STREAM_OPEN_FLAG_DELAY_ID_FC_UPDATES.rawValue))
}

public struct QuicStreamStartFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    
    public static let none = QuicStreamStartFlags([])
    public static let immediate = QuicStreamStartFlags(rawValue: UInt32(QUIC_STREAM_START_FLAG_IMMEDIATE.rawValue))
    public static let failBlocked = QuicStreamStartFlags(rawValue: UInt32(QUIC_STREAM_START_FLAG_FAIL_BLOCKED.rawValue))
    public static let shutdownOnFail = QuicStreamStartFlags(rawValue: UInt32(QUIC_STREAM_START_FLAG_SHUTDOWN_ON_FAIL.rawValue))
    public static let indicatePeerAccept = QuicStreamStartFlags(rawValue: UInt32(QUIC_STREAM_START_FLAG_INDICATE_PEER_ACCEPT.rawValue))
}

public struct QuicReceiveFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    
    public static let none = QuicReceiveFlags([])
    public static let zeroRtt = QuicReceiveFlags(rawValue: UInt32(QUIC_RECEIVE_FLAG_0_RTT.rawValue))
    public static let fin = QuicReceiveFlags(rawValue: UInt32(QUIC_RECEIVE_FLAG_FIN.rawValue))
}

public struct QuicSendFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    
    public static let none = QuicSendFlags([])
    public static let allowZeroRtt = QuicSendFlags(rawValue: UInt32(QUIC_SEND_FLAG_ALLOW_0_RTT.rawValue))
    public static let start = QuicSendFlags(rawValue: UInt32(QUIC_SEND_FLAG_START.rawValue))
    public static let fin = QuicSendFlags(rawValue: UInt32(QUIC_SEND_FLAG_FIN.rawValue))
    public static let dgramPriority = QuicSendFlags(rawValue: UInt32(QUIC_SEND_FLAG_DGRAM_PRIORITY.rawValue))
    public static let delaySend = QuicSendFlags(rawValue: UInt32(QUIC_SEND_FLAG_DELAY_SEND.rawValue))
}
