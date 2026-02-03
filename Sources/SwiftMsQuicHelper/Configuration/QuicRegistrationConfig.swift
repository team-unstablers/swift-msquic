//
//  QuicRegistrationConfig.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation

import MsQuic

/// Configuration options for creating a ``QuicRegistration``.
///
/// This structure holds the parameters needed to create a registration,
/// including the application name and execution profile.
public struct QuicRegistrationConfig {
    /// A human-readable name for the application.
    ///
    /// This name is used for logging and debugging purposes.
    public let appName: String

    /// The execution profile that controls threading and scheduling behavior.
    public let executionProfile: QuicExecutionProfile

    /// Creates a new registration configuration.
    ///
    /// - Parameters:
    ///   - appName: A human-readable name for the application.
    ///   - executionProfile: The execution profile to use.
    public init(appName: String, executionProfile: QuicExecutionProfile) {
        self.appName = appName
        self.executionProfile = executionProfile
    }
}

