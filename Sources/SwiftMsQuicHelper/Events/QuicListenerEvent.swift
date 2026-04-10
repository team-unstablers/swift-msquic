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
public enum QuicListenerEvent: Sendable {
    /// A new connection has been received.
    ///
    /// - Parameter info: Information about the incoming connection.
    case newConnection(info: NewConnectionInfo)

    /// The listener stop operation has completed.
    case stopComplete

    /// An unknown event type was received.
    case unknown

    /// Information about a new incoming connection.
    ///
    /// The underlying MsQuic connection handle must be consumed synchronously
    /// from inside the ``QuicListener/ConnectionHandler`` callback by calling
    /// ``accept(configuration:streamHandler:)``. Do not store this value beyond
    /// the callback — the raw handle is only valid while MsQuic is waiting for
    /// the handler to return.
    ///
    /// `NewConnectionInfo` is marked `@unchecked Sendable` because it holds a
    /// raw `HQUIC`. The handle is write-once (set at construction by the
    /// converter) and read once (by `accept(...)`), so there is no concurrent
    /// mutation to guard against.
    public struct NewConnectionInfo: @unchecked Sendable {
        /// The raw connection handle from MsQuic.
        ///
        /// Intentionally internal: callers should use
        /// ``accept(configuration:streamHandler:)`` instead of touching the
        /// raw handle directly.
        internal let rawConnectionHandle: HQUIC

        /// The server name (SNI) requested by the client, if any.
        public let serverName: String?

        /// The ALPN protocol negotiated with the client.
        public let negotiatedAlpn: String?

        /// The local address the connection was received on.
        public let localAddress: QuicAddress

        /// The remote address of the client.
        public let remoteAddress: QuicAddress

        internal init(
            rawConnectionHandle: HQUIC,
            serverName: String?,
            negotiatedAlpn: String?,
            localAddress: QuicAddress,
            remoteAddress: QuicAddress
        ) {
            self.rawConnectionHandle = rawConnectionHandle
            self.serverName = serverName
            self.negotiatedAlpn = negotiatedAlpn
            self.localAddress = localAddress
            self.remoteAddress = remoteAddress
        }

        /// Accepts the incoming connection and wraps it in a ``QuicConnection``.
        ///
        /// Call this from inside the ``QuicListener/ConnectionHandler`` closure
        /// to adopt the raw MsQuic connection handle. After this returns, the
        /// returned ``QuicConnection`` owns the handle and will close it on
        /// deinit.
        ///
        /// - Parameters:
        ///   - configuration: The configuration to apply to the new connection.
        ///   - streamHandler: Optional handler for streams initiated by the peer.
        /// - Returns: A fully-configured ``QuicConnection`` ready for use.
        /// - Throws: ``QuicError`` if the configuration cannot be applied.
        public func accept(
            configuration: QuicConfiguration,
            streamHandler: QuicConnection.StreamHandler? = nil
        ) throws -> QuicConnection {
            return try QuicConnection(
                handle: rawConnectionHandle,
                configuration: configuration,
                streamHandler: streamHandler
            )
        }
    }
}
