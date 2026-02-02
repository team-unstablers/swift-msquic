//
//  QuicOpenSwift.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import SwiftMsQuic



public struct SwiftMsQuicAPI {
    public static let shared = Self()
    private static var _MsQuic = SwiftMsQuic.MsQuic as! UnsafePointer<QUIC_API_TABLE>?
    
    public static var MsQuic: QUIC_API_TABLE {
        guard let msQuic = _MsQuic else {
            fatalError("MsQuic not initialized! call SwiftMsQuicAPI.open() first")
        }
        
        return msQuic.pointee
    }
    
    /// wraps MsQuicOpen2()
    public static func open() -> QuicStatus {
        return QuicStatus(MsQuicOpen2(&_MsQuic))
    }
    
    /// wraps MsQuicClose()
    public static func close() {
        MsQuicClose(_MsQuic)
    }
}




