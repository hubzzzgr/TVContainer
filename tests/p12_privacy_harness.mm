#import <Foundation/Foundation.h>
#import "../ZSign/TVReceiverIdentity.h"
#import "../ZSign/zsigner.h"
#include "../ZSign/openssl.h"
#include <openssl/pkcs12.h>
#include <openssl/err.h>
#include <unistd.h>
#include <assert.h>

int main(void) {
    @autoreleasepool {
        NSString *password = NSUUID.UUID.UUIDString;
        NSData *data = [TVReceiverIdentity createForDevice:@"Disposable privacy fixture" password:password error:nil];
        assert(data);
        const unsigned char *cursor = (const unsigned char *)data.bytes;
        PKCS12 *original = d2i_PKCS12(NULL, &cursor, (long)data.length);
        EVP_PKEY *key = NULL; X509 *cert = NULL;
        assert(original && PKCS12_parse(original, password.UTF8String, &key, &cert, NULL));
        PKCS12_free(original);
        assert(X509_NAME_add_entry_by_txt(X509_get_subject_name(cert), "OU", MBSTRING_ASC,
            (const unsigned char *)"TESTTEAM001", -1, -1, 0));
        assert(X509_set_issuer_name(cert, X509_get_subject_name(cert)));
        assert(X509_sign(cert, key, EVP_sha256()) > 0);
        PKCS12 *valid = PKCS12_create(password.UTF8String, "Fixture", key, cert, NULL,
            NID_pbe_WithSHA1And3_Key_TripleDES_CBC, NID_pbe_WithSHA1And3_Key_TripleDES_CBC, 2048, 2048, 0);
        assert(valid && PKCS12_set_mac(valid, password.UTF8String, -1, NULL, 0, 2048, EVP_sha1()));
        unsigned char *encoded = NULL;
        int length = i2d_PKCS12(valid, &encoded);
        assert(length > 0);
        NSData *withTeam = [NSData dataWithBytes:encoded length:(NSUInteger)length];
        OPENSSL_free(encoded); PKCS12_free(valid); EVP_PKEY_free(key); X509_free(cert);

        // Single-threaded capture of disposable fixtures only. Never print raw
        // captured diagnostics; the test asserts that no output was produced.
        FILE *capture = tmpfile(); assert(capture);
        int out = dup(STDOUT_FILENO), err = dup(STDERR_FILENO);
        fflush(stdout); fflush(stderr);
        dup2(fileno(capture), STDOUT_FILENO); dup2(fileno(capture), STDERR_FILENO);
        NSString *wrong = [ZSigner getTeamIdWithCert:withTeam pass:@"incorrect fixture password" quiet:YES];
        NSString *noTeam = [ZSigner getTeamIdWithCert:data pass:password quiet:YES];
        NSString *team = [ZSigner getTeamIdWithCert:withTeam pass:password quiet:YES];
        NSData *malformed = [@"invalid fixture" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *invalid = [ZSigner getTeamIdWithCert:malformed pass:@"unused" quiet:YES];
        fflush(stdout); fflush(stderr);
        long quietBytes = ftell(capture);
        // The suppression scope must restore diagnostics for unrelated signers.
        ERR_raise(ERR_LIB_USER, ERR_R_PASSED_INVALID_ARGUMENT);
        ZSignAsset::CMSError();
        fflush(stdout); fflush(stderr);
        long restoredBytes = ftell(capture);
        dup2(out, STDOUT_FILENO); dup2(err, STDERR_FILENO); close(out); close(err); fclose(capture);
        assert(!wrong.length && !noTeam.length && !invalid.length && [team isEqual:@"TESTTEAM001"]);
        assert(quietBytes == 0 && restoredBytes > quietBytes);
        puts("P12 privacy tests passed: correct/wrong/empty-team/malformed identities, no receiver diagnostics, normal signer diagnostics restored.");
    }
}
