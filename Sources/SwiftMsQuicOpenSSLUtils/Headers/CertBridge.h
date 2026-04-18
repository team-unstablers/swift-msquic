//
//  CertBridge.h
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/4/26.
//

#ifndef CERT_BRIDGE_H
#define CERT_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Result of a single DER certificate extraction.
typedef struct {
    uint8_t *data;    ///< DER-encoded certificate bytes (caller must free with CertBridge_Free)
    int length;       ///< Length in bytes, or negative on error
} CertBridge_DERCert;

/// Result of extracting a certificate chain.
typedef struct {
    CertBridge_DERCert *certs;  ///< Array of DER certs (caller must free each .data, then free the array)
    int count;                   ///< Number of certificates in the chain
} CertBridge_DERChain;

/// Extracts DER-encoded bytes from an OpenSSL X509 pointer.
///
/// @param x509 Pointer to an OpenSSL X509 structure.
/// @return A DERCert with the encoded data. On error, data is NULL and length is negative.
CertBridge_DERCert CertBridge_CopyDERFromX509(const void *x509);

/// Extracts DER-encoded certificate chain from an OpenSSL X509_STORE_CTX.
/// Skips the leaf certificate (index 0) — returns only the chain certs.
///
/// @param storeContext Pointer to an OpenSSL X509_STORE_CTX structure.
/// @return A DERChain with the extracted certificates. Empty chain on NULL input.
CertBridge_DERChain CertBridge_CopyDERChainFromStoreContext(const void *storeContext);

/// Frees memory allocated by CertBridge functions.
void CertBridge_Free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif /* CERT_BRIDGE_H */
