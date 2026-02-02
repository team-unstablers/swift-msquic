//
//  QuicListenerEvent.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import MsQuic

public enum QuicListenerEvent {
    case newConnection(info: NewConnectionInfo)
    case stopComplete
    case unknown
    
    public struct NewConnectionInfo {
        /// Raw connection handle from MsQuic. 
        /// You must wrap this with `QuicConnection` to use it.
        public let connection: HQUIC
        
        public let serverName: String?
        public let negotiatedAlpn: String?
        public let localAddress: QuicAddress
        public let remoteAddress: QuicAddress
    }
}
