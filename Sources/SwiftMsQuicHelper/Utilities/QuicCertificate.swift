//
//  QuicCertificate.swift
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/4/26.
//

#if canImport(Security)
import Security

public typealias QuicCertificate = SecCertificate
#else
public typealias QuicCertificate = UnsafePointer
#endif
