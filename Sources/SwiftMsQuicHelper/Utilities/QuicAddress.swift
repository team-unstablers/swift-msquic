//
//  QuicAddress.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct QuicAddress: CustomStringConvertible, Sendable {
    internal var raw: QUIC_ADDR
    
    public init(_ raw: QUIC_ADDR) {
        self.raw = raw
    }
    
    public init(ip: String, port: UInt16) {
        var addr = QUIC_ADDR()
        // Try IPv4 first
        if inet_pton(AF_INET, ip, &addr.Ipv4.sin_addr) == 1 {
            addr.Ipv4.sin_family = sa_family_t(AF_INET)
            addr.Ipv4.sin_port = port.bigEndian
            self.raw = addr
            return
        }
        
        // Try IPv6
        if inet_pton(AF_INET6, ip, &addr.Ipv6.sin6_addr) == 1 {
            addr.Ipv6.sin6_family = sa_family_t(AF_INET6)
            addr.Ipv6.sin6_port = port.bigEndian
            self.raw = addr
            return
        }
        
        // Default to empty/unspecified if parsing fails
        // (Alternatively, we could throw, but this init is often used for convenience)
        self.raw = QUIC_ADDR()
    }
    
    public init(port: UInt16, family: Family = .unspecified) {
        var addr = QUIC_ADDR()
        switch family {
        case .ipv4:
            addr.Ipv4.sin_family = sa_family_t(AF_INET)
            addr.Ipv4.sin_port = port.bigEndian
        case .ipv6:
            addr.Ipv6.sin6_family = sa_family_t(AF_INET6)
            addr.Ipv6.sin6_port = port.bigEndian
        case .unspecified:
            // MsQuic treats AF_UNSPEC as "listen on both IPv4 and IPv6".
            // Keep address zeroed; set port in the union (IPv6 view) like QuicAddrSetPort does.
            addr.Ip.sa_family = sa_family_t(AF_UNSPEC)
            addr.Ipv6.sin6_port = port.bigEndian
        }
        self.raw = addr
    }
    
    public enum Family {
        case ipv4
        case ipv6
        case unspecified
    }
    
    public var family: Family {
        switch Int32(raw.Ip.sa_family) {
        case AF_INET: return .ipv4
        case AF_INET6: return .ipv6
        default: return .unspecified
        }
    }
    
    public var port: UInt16 {
        switch family {
        case .ipv4:
            return UInt16(bigEndian: raw.Ipv4.sin_port)
        case .ipv6:
            return UInt16(bigEndian: raw.Ipv6.sin6_port)
        default:
            return 0
        }
    }
    
    public var description: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        
        switch family {
        case .ipv4:
            var addr = raw.Ipv4.sin_addr
            inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
        case .ipv6:
            var addr = raw.Ipv6.sin6_addr
            inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
        default:
            return "Unspecified"
        }
        
        return String(cString: buffer) + ":\(port)"
    }
    
    internal func withUnsafeAddress<T>(_ body: (UnsafePointer<QUIC_ADDR>) throws -> T) rethrows -> T {
        return try withUnsafePointer(to: raw) {
            try body($0)
        }
    }
}
