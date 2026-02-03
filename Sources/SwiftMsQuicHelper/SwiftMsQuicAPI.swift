//
//  QuicOpenSwift.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import MsQuic



/// The main entry point for initializing and accessing the MsQuic library.
///
/// Before using any SwiftMsQuicHelper APIs, you must call ``open()`` to initialize
/// the MsQuic library. When finished, call ``close()`` to release resources.
///
/// ## Example
///
/// ```swift
/// // Initialize MsQuic
/// try SwiftMsQuicAPI.open().throwIfFailed()
/// defer { SwiftMsQuicAPI.close() }
///
/// // Use SwiftMsQuicHelper APIs...
/// ```
///
/// ## Topics
///
/// ### Initialization
///
/// - ``open()``
/// - ``close()``
///
/// ### Internal Access
///
/// - ``MsQuic``
public struct SwiftMsQuicAPI {
    /// Shared instance (for compatibility).
    public static let shared = Self()
    private static var _MsQuic: UnsafeRawPointer? = nil

    /// The raw MsQuic API table.
    ///
    /// This provides direct access to the underlying MsQuic C API. Most users
    /// should use the high-level Swift wrappers instead.
    ///
    /// - Important: ``open()`` must be called before accessing this property.
    public static var MsQuic: QUIC_API_TABLE {
        guard let msQuic = _MsQuic else {
            fatalError("MsQuic not initialized! call SwiftMsQuicAPI.open() first")
        }

        let apiTable = msQuic.bindMemory(to: QUIC_API_TABLE.self, capacity: 1)
        return apiTable.pointee
    }

    /// Opens and initializes the MsQuic library.
    ///
    /// Call this method once at application startup before using any other
    /// SwiftMsQuicHelper APIs. Check the returned status to ensure initialization succeeded.
    ///
    /// ```swift
    /// try SwiftMsQuicAPI.open().throwIfFailed()
    /// ```
    ///
    /// - Returns: A status indicating whether initialization succeeded.
    public static func open() -> QuicStatus {
        return QuicStatus(MsQuicOpenVersion(UInt32(QUIC_API_VERSION_2), &_MsQuic))
    }

    /// Closes and releases the MsQuic library.
    ///
    /// Call this method when you're finished using QUIC to release all resources.
    /// Typically called in a `defer` block after ``open()``.
    ///
    /// - Important: All QUIC objects must be released before calling this method.
    public static func close() {
        MsQuicClose(_MsQuic)
    }
}




