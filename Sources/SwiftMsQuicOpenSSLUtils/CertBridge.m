//
//  CertBridge.m
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/4/26.
//


#import <Foundation/Foundation.h>
#import <Security/Security.h>

#include "openssl/x509.h"
#include "openssl/x509_vfy.h"
#include "openssl/crypto.h"

#import "CertBridge.h"

static NSString * const kCertBridgeErrorDomain = @"pl.unstabler.opensource.swift-msquic.utils.openssl";

typedef NS_ENUM(NSInteger, CertBridgeErrorCode) {
    CertBridgeErrorCodeNullInput = -1,
    CertBridgeErrorCodeDEREncodingFailed = -2,
    CertBridgeErrorCodeSecCertificateCreationFailed = -3,
};

@implementation CertBridge

static CFArrayRef CopyEmptyCertificateArray(void) {
    return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
}

+ (SecCertificateRef) copySecCertificateFromOpenSSLX509: (const void *) x509 error: (NSError **) error {
    if (x509 == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain: kCertBridgeErrorDomain
                                         code: CertBridgeErrorCodeNullInput
                                     userInfo: @{ NSLocalizedDescriptionKey: @"X509 pointer is NULL" }];
        }
        return nil;
    }

    // i2d_X509: Convert X509 to DER format
    // When out is NULL, OpenSSL allocates memory and returns the pointer
    unsigned char *derData = NULL;
    int derLength = i2d_X509((X509 *)x509, &derData);

    if (derLength <= 0 || derData == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain: kCertBridgeErrorDomain
                                         code: CertBridgeErrorCodeDEREncodingFailed
                                     userInfo: @{ NSLocalizedDescriptionKey: @"Failed to encode X509 to DER format" }];
        }
        return nil;
    }

    // Create CFData from DER bytes
    CFDataRef cfData = CFDataCreate(kCFAllocatorDefault, derData, derLength);

    // Free the DER buffer allocated by OpenSSL
    OPENSSL_free(derData);

    if (cfData == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain: kCertBridgeErrorDomain
                                         code: CertBridgeErrorCodeSecCertificateCreationFailed
                                     userInfo: @{ NSLocalizedDescriptionKey: @"Failed to create CFData from DER data" }];
        }
        return nil;
    }

    // Create SecCertificateRef from DER data
    SecCertificateRef certificate = SecCertificateCreateWithData(kCFAllocatorDefault, cfData);

    // Release the CFData (SecCertificateCreateWithData copies the data)
    CFRelease(cfData);

    if (certificate == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain: kCertBridgeErrorDomain
                                         code: CertBridgeErrorCodeSecCertificateCreationFailed
                                     userInfo: @{ NSLocalizedDescriptionKey: @"Failed to create SecCertificateRef from DER data" }];
        }
        return nil;
    }

    return certificate;
}

+ (CFArrayRef) copySecCertificateArrayFromOpenSSLStackX509: (const void *) stackX509 error: (NSError **) error {
    if (stackX509 == NULL) {
        return CopyEmptyCertificateArray();
    }

    STACK_OF(X509) *stack = (STACK_OF(X509) *)stackX509;
    int count = sk_X509_num(stack);

    if (count <= 1) {
        return CopyEmptyCertificateArray();
    }

    // Create mutable array with SecCertificateRef callbacks
    CFMutableArrayRef array = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);

    if (array == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain: kCertBridgeErrorDomain
                                         code: CertBridgeErrorCodeSecCertificateCreationFailed
                                     userInfo: @{ NSLocalizedDescriptionKey: @"Failed to create CFMutableArray" }];
        }
        return nil;
    }

    for (int i = 1; i < count; i++) {
        X509 *x509 = sk_X509_value(stack, i);

        NSError *certError = nil;
        SecCertificateRef cert = [self copySecCertificateFromOpenSSLX509: x509 error: &certError];

        if (cert == NULL) {
            // Clean up on failure
            CFRelease(array);
            if (error != NULL) {
                *error = certError;
            }
            return nil;
        }

        // CFArrayAppendValue retains the object
        CFArrayAppendValue(array, cert);

        // Release our reference (array now owns it)
        CFRelease(cert);
    }

    return array;
}

+ (CFArrayRef) copySecCertificateArrayFromOpenSSLStoreContext: (const void *) storeContext error: (NSError **) error {
    if (storeContext == NULL) {
        return CopyEmptyCertificateArray();
    }

    X509_STORE_CTX *context = (X509_STORE_CTX *)storeContext;
    X509_verify_cert(context);
    
    STACK_OF(X509) *stack = X509_STORE_CTX_get0_chain(context);

    return [self copySecCertificateArrayFromOpenSSLStackX509: stack error: error];
}

@end
