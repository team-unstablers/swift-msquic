//
//  QuicRegistrationConfig.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation

import MsQuic

public struct QuicRegistrationConfig {
    public let appName: String
    public let executionProfile: QuicExecutionProfile
    
    public init(appName: String, executionProfile: QuicExecutionProfile) {
        self.appName = appName
        self.executionProfile = executionProfile
    }
}

