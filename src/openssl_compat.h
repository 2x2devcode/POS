// Copyright (c) 2009-2012 The Bitcoin developers
// Distributed under the MIT/X11 software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.
//
// Compatibility helpers for OpenSSL 1.0 / 1.1 / 3.x APIs.

#ifndef BITCOIN_OPENSSL_COMPAT_H
#define BITCOIN_OPENSSL_COMPAT_H

#include <openssl/opensslv.h>
#include <openssl/ecdsa.h>
#include <openssl/evp.h>
#include <openssl/crypto.h>

#if OPENSSL_VERSION_NUMBER < 0x10100000L
# include <openssl/bn.h>
# include <openssl/ssl.h>
#endif

/* OpenSSL 1.1+ made ECDSA_SIG opaque. */
static inline void ECDSA_SIG_get_r_s(const ECDSA_SIG *sig, const BIGNUM **r, const BIGNUM **s)
{
#if OPENSSL_VERSION_NUMBER < 0x10100000L
    *r = sig->r;
    *s = sig->s;
#else
    ECDSA_SIG_get0(sig, r, s);
#endif
}

static inline int ECDSA_SIG_set_r_s(ECDSA_SIG *sig, BIGNUM *r, BIGNUM *s)
{
#if OPENSSL_VERSION_NUMBER < 0x10100000L
    if (r) {
        BN_clear_free(sig->r);
        sig->r = r;
    }
    if (s) {
        BN_clear_free(sig->s);
        sig->s = s;
    }
    return 1;
#else
    // OpenSSL 1.1+/3 ECDSA_SIG_set0() requires BOTH r and s non-NULL.
    // Callers historically passed NULL to keep the existing component — emulate that.
    const BIGNUM *cur_r = NULL, *cur_s = NULL;
    ECDSA_SIG_get0(sig, &cur_r, &cur_s);
    BIGNUM *new_r = r ? r : (cur_r ? BN_dup(cur_r) : NULL);
    BIGNUM *new_s = s ? s : (cur_s ? BN_dup(cur_s) : NULL);
    if (!new_r || !new_s) {
        if (!r && new_r) BN_free(new_r);
        if (!s && new_s) BN_free(new_s);
        return 0;
    }
    return ECDSA_SIG_set0(sig, new_r, new_s);
#endif
}

static inline EVP_CIPHER_CTX *EVP_CIPHER_CTX_new_compat(void)
{
#if OPENSSL_VERSION_NUMBER < 0x10100000L
    EVP_CIPHER_CTX *ctx = (EVP_CIPHER_CTX *)OPENSSL_malloc(sizeof(EVP_CIPHER_CTX));
    if (ctx)
        EVP_CIPHER_CTX_init(ctx);
    return ctx;
#else
    return EVP_CIPHER_CTX_new();
#endif
}

static inline void EVP_CIPHER_CTX_free_compat(EVP_CIPHER_CTX *ctx)
{
    if (!ctx)
        return;
#if OPENSSL_VERSION_NUMBER < 0x10100000L
    EVP_CIPHER_CTX_cleanup(ctx);
    OPENSSL_free(ctx);
#else
    EVP_CIPHER_CTX_free(ctx);
#endif
}

static inline const char *OpenSSLVersionString(void)
{
#if OPENSSL_VERSION_NUMBER < 0x10100000L
    return SSLeay_version(SSLEAY_VERSION);
#else
    return OpenSSL_version(OPENSSL_VERSION);
#endif
}

#endif // BITCOIN_OPENSSL_COMPAT_H
