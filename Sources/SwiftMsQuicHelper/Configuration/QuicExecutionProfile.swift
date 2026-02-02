//
//  QuicExecutionProfile.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation

import MsQuic

public enum QuicExecutionProfile {
    case lowLatency
    case scavenger
    case maxThroughput
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
