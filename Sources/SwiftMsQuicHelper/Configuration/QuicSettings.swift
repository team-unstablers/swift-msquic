//
//  QuicSettings.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic

public struct QuicSettings {
    public var maxBytesPerKey: UInt64?
    public var handshakeIdleTimeoutMs: UInt64?
    public var idleTimeoutMs: UInt64?
    public var maxAckDelayMs: UInt32?
    public var disconnectTimeoutMs: UInt32?
    public var keepAliveIntervalMs: UInt32?
    public var peerBidiStreamCount: UInt16?
    public var peerUnidiStreamCount: UInt16?
    
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
        if let val = peerBidiStreamCount {
            settings.PeerBidiStreamCount = val
            flags |= (1 << 18)
        }
        if let val = peerUnidiStreamCount {
            settings.PeerUnidiStreamCount = val
            flags |= (1 << 19)
        }
        
        settings.IsSetFlags = flags
        
        return try body(&settings)
    }
}
