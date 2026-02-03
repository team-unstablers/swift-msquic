//
//  QuicListenerEvent.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic

/// Events that can occur on a QUIC listener.
///
/// These events are used internally to manage listener state.
/// Use ``QuicListener/onNewConnection(_:)`` for a higher-level API.
public enum QuicListenerEvent {
    /// A new connection has been received.
    ///
    /// - Parameter info: Information about the incoming connection.
    case newConnection(info: NewConnectionInfo)

    /// The listener stop operation has completed.
    case stopComplete

    /// An unknown event type was received.
    case unknown

    /// Information about a new incoming connection.
    public struct NewConnectionInfo {
        /// The raw connection handle from MsQuic.
        ///
        /// You must wrap this with ``QuicConnection/init(handle:configuration:streamHandler:)``
        /// to use it.
        public let connection: HQUIC

        /// The server name (SNI) requested by the client, if any.
        public let serverName: String?

        /// The ALPN protocol negotiated with the client.
        public let negotiatedAlpn: String?

        /// The local address the connection was received on.
        public let localAddress: QuicAddress

        /// The remote address of the client.
        public let remoteAddress: QuicAddress
    }
}
