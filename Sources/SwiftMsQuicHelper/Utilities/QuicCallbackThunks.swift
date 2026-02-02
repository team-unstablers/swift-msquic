//
//  QuicCallbackThunks.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import SwiftMsQuic

internal func quicListenerCallback(
    _ listener: HQUIC?,
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafeMutablePointer<QUIC_LISTENER_EVENT>?
) -> QuicStatusRawValue {
    guard let context = context, let event = event else {
        return QuicStatus.invalidParameter.rawValue
    }
    let obj = QuicListener.fromCInteropHandle(context)
    return obj.handleEvent(event.pointee).rawValue
}

internal func quicConnectionCallback(
    _ connection: HQUIC?,
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafeMutablePointer<QUIC_CONNECTION_EVENT>?
) -> QuicStatusRawValue {
    guard let context = context, let event = event else {
        return QuicStatus.invalidParameter.rawValue
    }
    let obj = QuicConnection.fromCInteropHandle(context)
    return obj.handleEvent(event.pointee).rawValue
}

internal func quicStreamCallback(
    _ stream: HQUIC?,
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafeMutablePointer<QUIC_STREAM_EVENT>?
) -> QuicStatusRawValue {
    guard let context = context, let event = event else {
        return QuicStatus.invalidParameter.rawValue
    }
    let obj = QuicStream.fromCInteropHandle(context)
    return obj.handleEvent(event.pointee).rawValue
}
