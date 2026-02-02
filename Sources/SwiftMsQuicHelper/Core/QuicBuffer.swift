//
//  QuicBuffer.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic

public struct QuicBuffer {
    public let data: Data
    
    public init(_ data: Data) {
        self.data = data
    }
    
    public init(_ bytes: [UInt8]) {
        self.data = Data(bytes)
    }
    
    public init(_ string: String, encoding: String.Encoding = .utf8) {
        self.data = string.data(using: encoding) ?? Data()
    }
    
    /// Use this when passing a single QUIC_BUFFER to C API
    internal func withUnsafeQuicBuffer<T>(_ body: (UnsafePointer<QUIC_BUFFER>) throws -> T) rethrows -> T {
        try data.withUnsafeBytes { rawBuffer in
            // QUIC_BUFFER definition:
            // struct QUIC_BUFFER {
            //     uint32_t Length;
            //     uint8_t* Buffer;
            // }
            // Note: rawBuffer.baseAddress is void*, needs casting to uint8_t*
            
            var buffer = QUIC_BUFFER(
                Length: UInt32(data.count),
                Buffer: C_CAST(rawBuffer.baseAddress)
            )
            return try body(&buffer)
        }
    }
}

/// Helper for C casting (void* -> uint8_t*)
/// In Swift, UnsafeRawPointer (void*) cannot be directly passed to UnsafeMutablePointer<UInt8> (uint8_t*)
/// But MsQuic API expects uint8_t*.
@inline(__always)
private func C_CAST<T>(_ ptr: UnsafeRawPointer?) -> UnsafeMutablePointer<T>? {
    guard let ptr = ptr else { return nil }
    return UnsafeMutablePointer<T>(mutating: ptr.assumingMemoryBound(to: T.self))
}


/// Use this when passing an array of QUIC_BUFFERs (e.g. ALPN buffers)
internal func withQuicBufferArray<T>(_ buffers: [QuicBuffer], _ body: (UnsafePointer<QUIC_BUFFER>, UInt32) throws -> T) rethrows -> T {
    // We need to keep the Data objects alive while the C array is being used.
    // Also, we need to construct an array of QUIC_BUFFER structs.
    
    // 1. Flatten the data into a structure that we can get pointers to.
    // Actually, we can just map to QUIC_BUFFER, but we need the underlying pointers to be valid.
    // data.withUnsafeBytes is the only safe way. Nested closures are hard for dynamic arrays.
    
    // Strategy:
    // Create an array of temporary QUIC_BUFFERs.
    // Since QUIC_BUFFER stores a pointer, we must ensure the source Data is pinned.
    // We can use a recursive approach or `ContiguousArray` with `withUnsafeBufferPointer`.
    // However, Swift's Data doesn't guarantee pointer stability unless inside `withUnsafeBytes`.
    
    // Recursive approach to pin all Datas
    func pinNext(_ remaining: ArraySlice<QuicBuffer>, _ accumulated: [QUIC_BUFFER], _ body: (UnsafePointer<QUIC_BUFFER>, UInt32) throws -> T) rethrows -> T {
        guard let first = remaining.first else {
            // All pinned. Now pass the array of QUIC_BUFFERs.
            return try accumulated.withUnsafeBufferPointer { ptr in
                guard let baseAddress = ptr.baseAddress else {
                    // Should not happen if count > 0, but if empty:
                    // Create a dummy pointer or handle empty
                    var dummy = QUIC_BUFFER()
                    return try body(&dummy, 0)
                }
                return try body(baseAddress, UInt32(accumulated.count))
            }
        }
        
        return try first.data.withUnsafeBytes { rawBuffer in
            let qb = QUIC_BUFFER(
                Length: UInt32(first.data.count),
                Buffer: C_CAST(rawBuffer.baseAddress)
            )
            var newAccumulated = accumulated
            newAccumulated.append(qb)
            return try pinNext(remaining.dropFirst(), newAccumulated, body)
        }
    }
    
    if buffers.isEmpty {
        var dummy = QUIC_BUFFER()
        return try body(&dummy, 0)
    }
    
    return try pinNext(ArraySlice(buffers), [], body)
}
