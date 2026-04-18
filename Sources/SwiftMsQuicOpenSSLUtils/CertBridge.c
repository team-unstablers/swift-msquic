//
//  CertBridge.c
//  SwiftMsQuic
//
//  Created by Gyuhwan Park on 2/4/26.
//

#include <stdlib.h>
#include <string.h>

#include "openssl/x509.h"
#include "openssl/x509_vfy.h"
#include "openssl/crypto.h"

#include "CertBridge.h"

CertBridge_DERCert CertBridge_CopyDERFromX509(const void *x509) {
    CertBridge_DERCert result = { NULL, -1 };

    if (x509 == NULL) {
        return result;
    }

    unsigned char *der = NULL;
    int len = i2d_X509((X509 *)x509, &der);

    if (len <= 0 || der == NULL) {
        return result;
    }

    // Copy to stdlib-allocated buffer so caller can free() it
    result.data = (uint8_t *)malloc((size_t)len);
    if (result.data != NULL) {
        memcpy(result.data, der, (size_t)len);
        result.length = len;
    }

    OPENSSL_free(der);
    return result;
}

CertBridge_DERChain CertBridge_CopyDERChainFromStoreContext(const void *storeContext) {
    CertBridge_DERChain result = { NULL, 0 };

    if (storeContext == NULL) {
        return result;
    }

    X509_STORE_CTX *ctx = (X509_STORE_CTX *)storeContext;
    X509_verify_cert(ctx);

    STACK_OF(X509) *stack = X509_STORE_CTX_get0_chain(ctx);
    if (stack == NULL) {
        return result;
    }

    int total = sk_X509_num(stack);
    if (total <= 1) {
        // No chain certs (only leaf or empty)
        return result;
    }

    // Skip index 0 (leaf cert)
    int chainCount = total - 1;
    result.certs = (CertBridge_DERCert *)calloc((size_t)chainCount, sizeof(CertBridge_DERCert));
    if (result.certs == NULL) {
        return result;
    }

    result.count = chainCount;
    for (int i = 0; i < chainCount; i++) {
        X509 *cert = sk_X509_value(stack, i + 1);
        result.certs[i] = CertBridge_CopyDERFromX509(cert);
    }

    return result;
}

void CertBridge_Free(void *ptr) {
    free(ptr);
}
