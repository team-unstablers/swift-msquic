//
//  QuicStreamEvent.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import SwiftMsQuic

public enum QuicStreamEvent {
    case startComplete(status: QuicStatus, id: UInt64, peerAccepted: Bool)
    
    /// Data received. The data is copied from the underlying buffers.
    case receive(data: Data, flags: QuicReceiveFlags, absoluteOffset: UInt64, totalBufferLength: UInt64)
    
    case sendComplete(canceled: Bool, context: UnsafeMutableRawPointer?)
    case peerSendShutdown
    case peerSendAborted(errorCode: UInt64)
    case peerReceiveAborted(errorCode: UInt64)
    case sendShutdownComplete(graceful: Bool)
    case shutdownComplete(connectionShutdown: Bool, appCloseInProgress: Bool, connectionShutdownByApp: Bool, connectionClosedRemotely: Bool, connectionErrorCode: UInt64, connectionCloseStatus: QuicStatus)
    case idealSendBufferSize(byteCount: UInt64)
    case peerAccepted
    case cancelOnLoss(errorCode: UInt64)
    
    case unknown
}
