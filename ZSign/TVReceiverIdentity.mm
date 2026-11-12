#import "TVReceiverIdentity.h"
#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/pkcs12.h>
#include <openssl/rand.h>
#include <utility>
#include <initializer_list>

@implementation TVReceiverIdentity
+ (NSData *)createForDevice:(NSString *)deviceName error:(NSError **)error {
    EVP_PKEY_CTX *context = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, NULL);
    EVP_PKEY *key = NULL;
    X509 *cert = NULL;
    PKCS12 *container = NULL;
    NSData *result = nil;
    unsigned char *encoded = NULL;
    if (context && EVP_PKEY_keygen_init(context) > 0 && EVP_PKEY_CTX_set_rsa_keygen_bits(context, 2048) > 0 &&
        EVP_PKEY_keygen(context, &key) > 0 && (cert = X509_new())) {
        unsigned char serial[16];
        if (RAND_bytes(serial, sizeof(serial)) == 1) {
            serial[0] &= 0x7f;
            BIGNUM *number = BN_bin2bn(serial, sizeof(serial), NULL);
            ASN1_INTEGER *integer = number ? BN_to_ASN1_INTEGER(number, NULL) : NULL;
            if (integer) X509_set_serialNumber(cert, integer);
            ASN1_INTEGER_free(integer); BN_free(number);
            X509_set_version(cert, 2);
            X509_gmtime_adj(X509_getm_notBefore(cert), -300);
            X509_gmtime_adj(X509_getm_notAfter(cert), 5L * 365 * 24 * 60 * 60);
            X509_set_pubkey(cert, key);
            X509_NAME *name = X509_get_subject_name(cert);
            NSString *commonName = deviceName;
            while (commonName.length && [commonName lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 60)
                commonName = [commonName substringToIndex:[commonName rangeOfComposedCharacterSequenceAtIndex:commonName.length - 1].location];
            if (!commonName.length) commonName = @"TVContainer";
            X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_UTF8, (const unsigned char *)commonName.UTF8String, -1, -1, 0);
            X509_set_issuer_name(cert, name);
            for (const auto &extension : {std::pair<int, const char *>(NID_basic_constraints, "critical,CA:FALSE"),
                    {NID_key_usage, "critical,digitalSignature,keyEncipherment"}, {NID_ext_key_usage, "serverAuth,clientAuth"}}) {
                X509_EXTENSION *value = X509V3_EXT_conf_nid(NULL, NULL, extension.first, (char *)extension.second);
                if (value) { X509_add_ext(cert, value, -1); X509_EXTENSION_free(value); }
            }
            if (X509_sign(cert, key, EVP_sha256()) > 0) {
                // Legacy PKCS#12 encryption identifiers are supported by Apple's
                // importer. This blob exists only in memory and encrypted Keychain.
                container = PKCS12_create("", "TVContainer local TLS", key, cert, NULL,
                    NID_pbe_WithSHA1And3_Key_TripleDES_CBC, NID_pbe_WithSHA1And3_Key_TripleDES_CBC, 2048, 2048, 0);
                int length = container ? i2d_PKCS12(container, &encoded) : 0;
                if (length > 0) result = [NSData dataWithBytes:encoded length:(NSUInteger)length];
            }
        }
    }
    OPENSSL_free(encoded); PKCS12_free(container); X509_free(cert); EVP_PKEY_free(key); EVP_PKEY_CTX_free(context);
    if (!result && error) *error = [NSError errorWithDomain:@"TVContainer.Receiver" code:1
        userInfo:@{NSLocalizedDescriptionKey:@"Unable to create the receiver's TLS identity."}];
    return result;
}
@end
