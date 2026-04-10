//
//  QuicObject.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic
import os

/// Base class for all QUIC handle wrappers.
///
/// `QuicObject` provides common functionality for all QUIC objects, including
/// handle management and self-retention for callback safety.
///
/// - Note: This class is typically not used directly. Use the concrete subclasses
///   like ``QuicConnection``, ``QuicStream``, or ``QuicListener`` instead.
///   External subclassing is intentionally disallowed — the class is `public`
///   but not `open`, so only subclasses declared inside `SwiftMsQuicHelper`
///   itself are permitted.
///
/// `QuicObject` is marked `@unchecked Sendable` so that subclasses which are
/// themselves `@unchecked Sendable` can participate in `@Sendable` closures
/// (e.g. the `OSAllocatedUnfairLock.withLock` body). Thread safety is
/// provided by:
///
/// - `handle`: `nonisolated(unsafe)`, write-once in `init`, read by both
///   Swift tasks and MsQuic C callback threads. `HQUIC` is an opaque
///   pointer whose identity is stable post-init.
/// - `retainState`: protected by `OSAllocatedUnfairLock<RetainState>`.
/// - Subclasses carry their own per-instance locks for mutable state.
public class QuicObject: CInteropHandle, @unchecked Sendable {
    /// Internal MsQuic Handle.
    ///
    /// Marked `nonisolated(unsafe)` because writes are confined to `init`
    /// (or to the `init`-like path in subclasses that assign after calling
    /// `super.init()`), while reads happen from both the owning Swift task
    /// and arbitrary MsQuic worker threads inside C callbacks. The handle
    /// is an opaque pointer whose identity never changes after
    /// initialization, so concurrent reads are safe without additional
    /// synchronization.
    internal nonisolated(unsafe) var handle: HQUIC?

    /// Convenience accessor for the API table
    internal var api: QUIC_API_TABLE { SwiftMsQuicAPI.MsQuic }

    private struct RetainState: @unchecked Sendable {
        var retainedSelf: Unmanaged<AnyObject>?
    }
    private let retainState = OSAllocatedUnfairLock(initialState: RetainState())

    /// Whether this object has a valid handle.
    public var isValid: Bool { handle != nil }
    
    public init() {
        self.handle = nil
    }
    
    internal init(handle: HQUIC) {
        self.handle = handle
    }
    
    deinit {
        // Subclasses must override this to call the appropriate Close function
        // e.g., api.ConnectionClose(handle)
        // Since we cannot call virtual methods in deinit safely in some languages, 
        // but Swift allows it. However, it's better if subclasses handle their specific close logic.
        // We just ensure handle is nullified if we were doing manual management, but here ARC does the job.
        //
        // NOTE: We cannot enforce subclasses to call close() here. 
        // Subclasses SHOULD implement deinit { close() } or similar.
    }
    
    /// Retain self for callback lifetime to avoid use-after-free.
    internal func retainSelfForCallback() {
        // `withLockUnchecked` because the captured `self` (and the
        // `Unmanaged<AnyObject>` stored into `RetainState`) are not
        // Sendable. Serialization is still enforced by the underlying
        // unfair lock.
        retainState.withLockUnchecked { state in
            guard state.retainedSelf == nil else { return }
            state.retainedSelf = Unmanaged.passRetained(self as AnyObject)
        }
    }

    /// Release previously retained self. Safe to call multiple times.
    internal func releaseSelfFromCallback() {
        // `withLockUnchecked` because the return type
        // (`Unmanaged<AnyObject>?`) is not Sendable. Serialization is
        // still enforced by the underlying unfair lock.
        let retained = retainState.withLockUnchecked { state -> Unmanaged<AnyObject>? in
            let retained = state.retainedSelf
            state.retainedSelf = nil
            return retained
        }
        retained?.release()
    }
}
