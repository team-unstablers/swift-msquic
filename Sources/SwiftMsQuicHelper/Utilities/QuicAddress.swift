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

/// A network address for QUIC connections.
///
/// `QuicAddress` wraps IPv4 and IPv6 addresses for use with QUIC listeners
/// and connections.
///
/// ## Creating Addresses
///
/// ```swift
/// // Listen on all interfaces, port 443
/// let address = QuicAddress(port: 443)
///
/// // Specific IP and port
/// let address = QuicAddress(ip: "192.168.1.1", port: 443)
///
/// // IPv6
/// let address = QuicAddress(ip: "::1", port: 443)
/// ```
public struct QuicAddress: CustomStringConvertible, Sendable {
    internal var raw: QUIC_ADDR

    /// Creates an address from a raw MsQuic address.
    ///
    /// - Parameter raw: The raw MsQuic address structure.
    public init(_ raw: QUIC_ADDR) {
        self.raw = raw
    }

    /// Creates an address from an IP string and port.
    ///
    /// - Parameters:
    ///   - ip: The IP address as a string (IPv4 or IPv6).
    ///   - port: The port number.
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
    
    /// Creates an address for a specific port and address family.
    ///
    /// Use this initializer for listener addresses when you want to listen
    /// on all interfaces.
    ///
    /// - Parameters:
    ///   - port: The port number.
    ///   - family: The address family (IPv4, IPv6, or unspecified for both).
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
    
    /// The address family.
    public enum Family {
        /// IPv4 address.
        case ipv4
        /// IPv6 address.
        case ipv6
        /// Unspecified (accept both IPv4 and IPv6).
        case unspecified
    }

    /// The address family of this address.
    public var family: Family {
        switch Int32(raw.Ip.sa_family) {
        case AF_INET: return .ipv4
        case AF_INET6: return .ipv6
        default: return .unspecified
        }
    }
    
    /// The port number.
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

    /// A human-readable description of the address (e.g., "192.168.1.1:443").
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
