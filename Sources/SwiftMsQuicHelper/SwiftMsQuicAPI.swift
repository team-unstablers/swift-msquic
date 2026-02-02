//
//  QuicOpenSwift.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/3/26.
//

import MsQuic



public struct SwiftMsQuicAPI {
    public static let shared = Self()
    private static var _MsQuic: UnsafeRawPointer? = nil
    
    public static var MsQuic: QUIC_API_TABLE {
        guard let msQuic = _MsQuic else {
            fatalError("MsQuic not initialized! call SwiftMsQuicAPI.open() first")
        }
        
        let apiTable = msQuic as! UnsafePointer<QUIC_API_TABLE>
        
        return apiTable.pointee
    }
    
    /// wraps MsQuicOpen2()
    public static func open() -> QuicStatus {
        return QuicStatus(MsQuicOpenVersion(UInt32(QUIC_API_VERSION_2), &_MsQuic))
    }
    
    /// wraps MsQuicClose()
    public static func close() {
        MsQuicClose(_MsQuic)
    }
}




