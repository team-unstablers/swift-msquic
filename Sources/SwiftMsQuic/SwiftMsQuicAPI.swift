//
//  QuicOpenSwift.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import MsQuic
import os



/// The main entry point for initializing and accessing the MsQuic library.
///
/// Before using any SwiftMsQuic APIs, you must call ``open()`` to initialize
/// the MsQuic library. When finished, call ``close()`` to release resources.
///
/// ## Example
///
/// ```swift
/// // Initialize MsQuic
/// try SwiftMsQuicAPI.open().throwIfFailed()
/// defer { SwiftMsQuicAPI.close() }
///
/// // Use SwiftMsQuic APIs...
/// ```
///
/// ## Topics
///
/// ### Initialization
///
/// - ``open()``
/// - ``close()``
public enum SwiftMsQuicAPI {
    /// Lock-protected global state for the raw MsQuic API table pointer.
    ///
    /// `state` lock protects all mutable fields below. The raw pointer is
    /// written once by ``open()`` and cleared by ``close()``; readers acquire
    /// the lock to fetch the current value. The struct is `@unchecked
    /// Sendable` because `UnsafeRawPointer?` is not Sendable by default, yet
    /// all access is serialized through the lock.
    private struct ApiState: @unchecked Sendable {
        var rawAPI: UnsafeRawPointer?
    }
    private static let state = OSAllocatedUnfairLock(initialState: ApiState())

    /// The raw MsQuic API table.
    ///
    /// This provides direct access to the underlying MsQuic C API. SwiftMsQuic
    /// internals use this through per-object `api` accessors; it is not part of the
    /// public API surface.
    ///
    /// - Important: ``open()`` must be called before accessing this property.
    internal static var MsQuic: QUIC_API_TABLE {
        // `withLockUnchecked` is used because the return type
        // (`UnsafeRawPointer?`) is not Sendable. Serialization is still
        // enforced by the underlying unfair lock.
        let rawAPI = state.withLockUnchecked { $0.rawAPI }
        guard let rawAPI else {
            fatalError("MsQuic not initialized! call SwiftMsQuicAPI.open() first")
        }

        let apiTable = rawAPI.bindMemory(to: QUIC_API_TABLE.self, capacity: 1)
        return apiTable.pointee
    }

    /// Opens and initializes the MsQuic library.
    ///
    /// Call this method once at application startup before using any other
    /// SwiftMsQuic APIs. Check the returned status to ensure initialization succeeded.
    ///
    /// ```swift
    /// try SwiftMsQuicAPI.open().throwIfFailed()
    /// ```
    ///
    /// - Returns: A status indicating whether initialization succeeded.
    public static func open() -> QuicStatus {
        state.withLock { state in
            QuicStatus(MsQuicOpenVersion(UInt32(QUIC_API_VERSION_2), &state.rawAPI))
        }
    }

    /// Closes and releases the MsQuic library.
    ///
    /// Call this method when you're finished using QUIC to release all resources.
    /// Typically called in a `defer` block after ``open()``.
    ///
    /// - Important: All QUIC objects must be released before calling this method.
    public static func close() {
        state.withLock { state in
            MsQuicClose(state.rawAPI)
            state.rawAPI = nil
        }
    }
}
