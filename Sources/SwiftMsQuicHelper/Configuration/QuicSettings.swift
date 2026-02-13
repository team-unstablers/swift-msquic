//
//  QuicSettings.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic

/// QUIC protocol settings for connections and configurations.
///
/// Use this structure to customize QUIC behavior such as timeouts, stream limits,
/// and other protocol parameters. All properties are optional; only set properties
/// are applied to the configuration.
///
/// ## Example
///
/// ```swift
/// var settings = QuicSettings()
/// settings.idleTimeoutMs = 30000
/// settings.peerBidiStreamCount = 100
/// settings.keepAliveIntervalMs = 10000
///
/// let config = try QuicConfiguration(
///     registration: registration,
///     alpnBuffers: ["my-protocol"],
///     settings: settings
/// )
/// ```
public struct QuicSettings {
    /// Maximum number of bytes encrypted with a single key before key update.
    public var maxBytesPerKey: UInt64?

    /// Timeout in milliseconds for the TLS handshake to complete.
    public var handshakeIdleTimeoutMs: UInt64?

    /// Timeout in milliseconds for an idle connection before it's closed.
    public var idleTimeoutMs: UInt64?

    /// Timeout in microseconds used by MTU discovery search completion.
    public var mtuDiscoverySearchCompleteTimeoutUs: UInt64?

    /// Maximum TLS client-side send buffer size in bytes.
    public var tlsClientMaxSendBuffer: UInt32?

    /// Maximum TLS server-side send buffer size in bytes.
    public var tlsServerMaxSendBuffer: UInt32?

    /// Default per-stream receive window size in bytes.
    public var streamRecvWindowDefault: UInt32?

    /// Default per-stream receive buffer size in bytes.
    public var streamRecvBufferDefault: UInt32?

    /// Connection-level flow control window size in bytes.
    public var connFlowControlWindow: UInt32?

    /// Maximum worker queue delay in microseconds.
    public var maxWorkerQueueDelayUs: UInt32?

    /// Maximum number of stateless operations.
    public var maxStatelessOperations: UInt32?

    /// Initial congestion window size in packets.
    public var initialWindowPackets: UInt32?

    /// Send idle timeout in milliseconds.
    public var sendIdleTimeoutMs: UInt32?

    /// Initial RTT estimate in milliseconds.
    public var initialRttMs: UInt32?

    /// Maximum delay in milliseconds before sending an acknowledgment.
    public var maxAckDelayMs: UInt32?

    /// Timeout in milliseconds to wait for a connection to fully close.
    public var disconnectTimeoutMs: UInt32?

    /// Interval in milliseconds between keep-alive packets.
    ///
    /// Set this to prevent idle timeout when there's no data to send.
    public var keepAliveIntervalMs: UInt32?

    /// Maximum number of bidirectional streams the peer can open.
    public var peerBidiStreamCount: UInt16?

    /// Maximum number of unidirectional streams the peer can open.
    public var peerUnidiStreamCount: UInt16?

    /// Congestion control algorithm (`QUIC_CONGESTION_CONTROL_ALGORITHM` raw value).
    public var congestionControlAlgorithm: UInt16?

    /// Maximum binding-level stateless operations.
    public var maxBindingStatelessOperations: UInt16?

    /// Stateless operation expiration in milliseconds.
    public var statelessOperationExpirationMs: UInt16?

    /// Minimum path MTU.
    public var minimumMtu: UInt16?

    /// Maximum path MTU.
    public var maximumMtu: UInt16?

    /// Enable send buffering in MsQuic.
    ///
    /// Set this to `false` to use ``QuicStream/enqueue(_:)`` and
    /// ``QuicStream/drain(finalFlags:)`` with IDEAL_SEND_BUFFER_SIZE-based
    /// multi in-flight send control.
    public var sendBufferingEnabled: Bool?

    /// Enable packet pacing.
    public var pacingEnabled: Bool?

    /// Enable connection migration.
    public var migrationEnabled: Bool?

    /// Enable receiving QUIC datagrams on the connection.
    ///
    /// This must be enabled on both endpoints for datagram feature negotiation.
    public var datagramReceiveEnabled: Bool?

    /// Server resumption level (`QUIC_SERVER_RESUMPTION_LEVEL` raw value).
    public var serverResumptionLevel: UInt8?

    /// Max operations processed per drain.
    public var maxOperationsPerDrain: UInt8?

    /// Number of missing probes before MTU discovery fallback.
    public var mtuDiscoveryMissingProbeCount: UInt8?

    /// Destination CID update idle timeout in milliseconds.
    public var destCidUpdateIdleTimeoutMs: UInt32?

    /// Enable GREASE QUIC bit behavior.
    public var greaseQuicBitEnabled: Bool?

    /// Enable ECN.
    public var ecnEnabled: Bool?

    /// Enable HyStart.
    public var hyStartEnabled: Bool?

    /// Default receive window for locally-initiated bidirectional streams.
    public var streamRecvWindowBidiLocalDefault: UInt32?

    /// Default receive window for remotely-initiated bidirectional streams.
    public var streamRecvWindowBidiRemoteDefault: UInt32?

    /// Default receive window for unidirectional streams.
    public var streamRecvWindowUnidiDefault: UInt32?

    /// Creates a new settings instance with all properties unset.
    public init() { }
    
    internal func withUnsafeSettings<T>(_ body: (UnsafePointer<QUIC_SETTINGS>) throws -> T) rethrows -> T {
        var settings = QUIC_SETTINGS()
        
        // Zero initialize everything first (Swift structs are value types, but let's be explicit if needed, 
        // though default init of imported C struct usually zeros or requires all fields)
        // QUIC_SETTINGS has a lot of fields. We rely on the default initializer if available or init manually.
        // Actually, for C structs, Swift provides a memberwise initializer.
        // We should probably memset it to zero to be safe, or just use the initializer.
        // Since we only set what we need, and MsQuic uses IsSetFlags to check validity, it's fine.
        
        // Note: bit offsets must match msquic.h definition of QUIC_SETTINGS.IsSet
        //
        // uint64_t MaxBytesPerKey                         : 1;  (Bit 0)
        // uint64_t HandshakeIdleTimeoutMs                 : 1;  (Bit 1)
        // uint64_t IdleTimeoutMs                          : 1;  (Bit 2)
        // uint64_t MtuDiscoverySearchCompleteTimeoutUs    : 1;  (Bit 3)
        // uint64_t TlsClientMaxSendBuffer                 : 1;  (Bit 4)
        // uint64_t TlsServerMaxSendBuffer                 : 1;  (Bit 5)
        // uint64_t StreamRecvWindowDefault                : 1;  (Bit 6)
        // uint64_t StreamRecvBufferDefault                : 1;  (Bit 7)
        // uint64_t ConnFlowControlWindow                  : 1;  (Bit 8)
        // uint64_t MaxWorkerQueueDelayUs                  : 1;  (Bit 9)
        // uint64_t MaxStatelessOperations                 : 1;  (Bit 10)
        // uint64_t InitialWindowPackets                   : 1;  (Bit 11)
        // uint64_t SendIdleTimeoutMs                      : 1;  (Bit 12)
        // uint64_t InitialRttMs                           : 1;  (Bit 13)
        // uint64_t MaxAckDelayMs                          : 1;  (Bit 14)
        // uint64_t DisconnectTimeoutMs                    : 1;  (Bit 15)
        // uint64_t KeepAliveIntervalMs                    : 1;  (Bit 16)
        // uint64_t CongestionControlAlgorithm             : 1;  (Bit 17)
        // uint64_t PeerBidiStreamCount                    : 1;  (Bit 18)
        // uint64_t PeerUnidiStreamCount                   : 1;  (Bit 19)
        // uint64_t MaxBindingStatelessOperations          : 1;  (Bit 20)
        // uint64_t StatelessOperationExpirationMs         : 1;  (Bit 21)
        // uint64_t MinimumMtu                             : 1;  (Bit 22)
        // uint64_t MaximumMtu                             : 1;  (Bit 23)
        // uint64_t SendBufferingEnabled                   : 1;  (Bit 24)
        // uint64_t PacingEnabled                          : 1;  (Bit 25)
        // uint64_t MigrationEnabled                       : 1;  (Bit 26)
        // uint64_t DatagramReceiveEnabled                 : 1;  (Bit 27)
        // uint64_t ServerResumptionLevel                  : 1;  (Bit 28)
        // uint64_t MaxOperationsPerDrain                  : 1;  (Bit 29)
        // uint64_t MtuDiscoveryMissingProbeCount          : 1;  (Bit 30)
        // uint64_t DestCidUpdateIdleTimeoutMs             : 1;  (Bit 31)
        // uint64_t GreaseQuicBitEnabled                   : 1;  (Bit 32)
        // uint64_t EcnEnabled                             : 1;  (Bit 33)
        // uint64_t HyStartEnabled                         : 1;  (Bit 34)
        // uint64_t StreamRecvWindowBidiLocalDefault       : 1;  (Bit 35)
        // uint64_t StreamRecvWindowBidiRemoteDefault      : 1;  (Bit 36)
        // uint64_t StreamRecvWindowUnidiDefault           : 1;  (Bit 37)
        
        var flags: UInt64 = 0
        
        if let val = maxBytesPerKey {
            settings.MaxBytesPerKey = val
            flags |= (1 << 0)
        }
        if let val = handshakeIdleTimeoutMs {
            settings.HandshakeIdleTimeoutMs = val
            flags |= (1 << 1)
        }
        if let val = idleTimeoutMs {
            settings.IdleTimeoutMs = val
            flags |= (1 << 2)
        }
        if let val = mtuDiscoverySearchCompleteTimeoutUs {
            settings.MtuDiscoverySearchCompleteTimeoutUs = val
            flags |= (1 << 3)
        }
        if let val = tlsClientMaxSendBuffer {
            settings.TlsClientMaxSendBuffer = val
            flags |= (1 << 4)
        }
        if let val = tlsServerMaxSendBuffer {
            settings.TlsServerMaxSendBuffer = val
            flags |= (1 << 5)
        }
        if let val = streamRecvWindowDefault {
            settings.StreamRecvWindowDefault = val
            flags |= (1 << 6)
        }
        if let val = streamRecvBufferDefault {
            settings.StreamRecvBufferDefault = val
            flags |= (1 << 7)
        }
        if let val = connFlowControlWindow {
            settings.ConnFlowControlWindow = val
            flags |= (1 << 8)
        }
        if let val = maxWorkerQueueDelayUs {
            settings.MaxWorkerQueueDelayUs = val
            flags |= (1 << 9)
        }
        if let val = maxStatelessOperations {
            settings.MaxStatelessOperations = val
            flags |= (1 << 10)
        }
        if let val = initialWindowPackets {
            settings.InitialWindowPackets = val
            flags |= (1 << 11)
        }
        if let val = sendIdleTimeoutMs {
            settings.SendIdleTimeoutMs = val
            flags |= (1 << 12)
        }
        if let val = initialRttMs {
            settings.InitialRttMs = val
            flags |= (1 << 13)
        }
        if let val = maxAckDelayMs {
            settings.MaxAckDelayMs = val
            flags |= (1 << 14)
        }
        if let val = disconnectTimeoutMs {
            settings.DisconnectTimeoutMs = val
            flags |= (1 << 15)
        }
        if let val = keepAliveIntervalMs {
            settings.KeepAliveIntervalMs = val
            flags |= (1 << 16)
        }
        if let val = congestionControlAlgorithm {
            settings.CongestionControlAlgorithm = val
            flags |= (1 << 17)
        }
        if let val = peerBidiStreamCount {
            settings.PeerBidiStreamCount = val
            flags |= (1 << 18)
        }
        if let val = peerUnidiStreamCount {
            settings.PeerUnidiStreamCount = val
            flags |= (1 << 19)
        }
        if let val = maxBindingStatelessOperations {
            settings.MaxBindingStatelessOperations = val
            flags |= (1 << 20)
        }
        if let val = statelessOperationExpirationMs {
            settings.StatelessOperationExpirationMs = val
            flags |= (1 << 21)
        }
        if let val = minimumMtu {
            settings.MinimumMtu = val
            flags |= (1 << 22)
        }
        if let val = maximumMtu {
            settings.MaximumMtu = val
            flags |= (1 << 23)
        }
        if let val = sendBufferingEnabled {
            settings.SendBufferingEnabled = val ? 1 : 0
            flags |= (1 << 24)
        }
        if let val = pacingEnabled {
            settings.PacingEnabled = val ? 1 : 0
            flags |= (1 << 25)
        }
        if let val = migrationEnabled {
            settings.MigrationEnabled = val ? 1 : 0
            flags |= (1 << 26)
        }
        if let val = datagramReceiveEnabled {
            settings.DatagramReceiveEnabled = val ? 1 : 0
            flags |= (1 << 27)
        }
        if let val = serverResumptionLevel {
            settings.ServerResumptionLevel = val
            flags |= (1 << 28)
        }
        if let val = maxOperationsPerDrain {
            settings.MaxOperationsPerDrain = val
            flags |= (1 << 29)
        }
        if let val = mtuDiscoveryMissingProbeCount {
            settings.MtuDiscoveryMissingProbeCount = val
            flags |= (1 << 30)
        }
        if let val = destCidUpdateIdleTimeoutMs {
            settings.DestCidUpdateIdleTimeoutMs = val
            flags |= (1 << 31)
        }
        if let val = greaseQuicBitEnabled {
            settings.GreaseQuicBitEnabled = val ? 1 : 0
            flags |= (1 << 32)
        }
        if let val = ecnEnabled {
            settings.EcnEnabled = val ? 1 : 0
            flags |= (1 << 33)
        }
        if let val = hyStartEnabled {
            settings.HyStartEnabled = val ? 1 : 0
            flags |= (1 << 34)
        }
        if let val = streamRecvWindowBidiLocalDefault {
            settings.StreamRecvWindowBidiLocalDefault = val
            flags |= (1 << 35)
        }
        if let val = streamRecvWindowBidiRemoteDefault {
            settings.StreamRecvWindowBidiRemoteDefault = val
            flags |= (1 << 36)
        }
        if let val = streamRecvWindowUnidiDefault {
            settings.StreamRecvWindowUnidiDefault = val
            flags |= (1 << 37)
        }
        
        settings.IsSetFlags = flags
        
        return try body(&settings)
    }
}
