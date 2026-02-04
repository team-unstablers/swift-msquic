//
//  CertBridge.h
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/4/26.
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>

/// A bridge class for converting OpenSSL X509 structures to SecCertificateRef objects.
@interface CertBridge: NSObject

/// Constructs SecCertificateRef from OpenSSL X509 pointer.
/// @param x509 Pointer to OpenSSL X509 structure.
/// @param error Pointer to NSError object to capture any error that occurs during the conversion.
///
/// @return A SecCertificateRef object representing the certificate, or nil if an error occurred.
+ (SecCertificateRef) copySecCertificateFromOpenSSLX509: (const void *) x509 error: (NSError **) error;

/// Constructs an array of SecCertificateRef from OpenSSL STACK_OF(X509).
/// @param stackX509 Pointer to OpenSSL STACK_OF(X509) structure.
/// @param error Pointer to NSError object to capture any error that occurs during the conversion.
///
/// @return A CFArrayRef containing SecCertificateRef objects, or nil if an error occurred.
+ (CFArrayRef) copySecCertificateArrayFromOpenSSLStackX509: (const void *) stackX509 error: (NSError **) error;
@end
