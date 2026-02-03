//
//  QuicExecutionProfile.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation

import MsQuic

/// The execution profile that controls threading and scheduling behavior.
///
/// Choose an execution profile based on your application's needs:
///
/// - Use ``lowLatency`` for interactive applications that need fast response times.
/// - Use ``maxThroughput`` for applications that need to move large amounts of data.
/// - Use ``scavenger`` for background transfers that shouldn't interfere with other traffic.
/// - Use ``realTime`` for time-sensitive applications like audio/video streaming.
public enum QuicExecutionProfile {
    /// Optimized for low latency and fast response times.
    ///
    /// Best for interactive applications like chat, gaming, or API calls.
    case lowLatency

    /// Low-priority background processing.
    ///
    /// Best for background downloads or uploads that shouldn't interfere with
    /// other network traffic.
    case scavenger

    /// Optimized for maximum data throughput.
    ///
    /// Best for bulk data transfers like file uploads/downloads.
    case maxThroughput

    /// Optimized for real-time applications.
    ///
    /// Best for time-sensitive applications like audio/video streaming.
    case realTime
}

public extension QuicExecutionProfile {
    var asLibEnum: QUIC_EXECUTION_PROFILE {
        switch self {
        case .lowLatency:
            return QUIC_EXECUTION_PROFILE_LOW_LATENCY
        case .scavenger:
            return QUIC_EXECUTION_PROFILE_TYPE_SCAVENGER
        case .maxThroughput:
            return QUIC_EXECUTION_PROFILE_TYPE_MAX_THROUGHPUT
        case .realTime:
            return QUIC_EXECUTION_PROFILE_TYPE_REAL_TIME
        }
    }
}
