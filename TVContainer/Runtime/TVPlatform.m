#import "TVPlatform.h"
#import <Security/Security.h>
#import "../../LiveContainer/UIKitPrivate.h"
#import "../../LiveContainer/utils.h"
#include "TVProcessReexec.h"

void TVCaptureRelaunchContext(int argc, char *argv[]) {
    extern char **environ;
    TVPrepareReexec(NSBundle.mainBundle.executablePath.fileSystemRepresentation, argc, argv, environ);
}

BOOL TVRelaunch(void (^completion)(NSError *)) {
    [NSUserDefaults.lcUserDefaults synchronize];
    int result = TVPerformReexec();
    // Successful re-execution never returns. A rejected request leaves the
    // current UI alive, so an unsupported device does not drop to Home Screen.
    NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain code:result userInfo:nil];
    completion([NSError errorWithDomain:@"TVContainer" code:result userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"tvOS could not restart TVContainer in place (%@). The app has stayed open.", underlying.localizedDescription],
        NSUnderlyingErrorKey: underlying
    }]);
    return YES;
}
NSURL *TVStorageRoot(void) {
    const char *hostHome = getenv("LC_HOST_HOME_PATH") ?: getenv("HOME");
    return [NSURL fileURLWithPath:[NSString stringWithFormat:@"%s/Library/Caches/TVContainer", hostHome] isDirectory:YES];
}

static NSDictionary *identityQuery(void) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: @"com.kdt.tvcontainer.signing",
             (__bridge id)kSecAttrAccount: @"identity"};
}

NSDictionary *TVReadSigningIdentity(void) {
    NSMutableDictionary *query = identityQuery().mutableCopy;
    query[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess) return nil;
    NSData *data = CFBridgingRelease(result);
    return [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
}

static BOOL checkStatus(OSStatus status, NSError **error) {
    if (status == errSecSuccess) return YES;
    if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
    return NO;
}

BOOL TVSaveSigningIdentity(NSData *certificate, NSString *password, NSError **error) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"certificate": certificate, @"password": password}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data) return NO;
    NSDictionary *attributes = @{(__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)identityQuery(), (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *query = identityQuery().mutableCopy;
        [query addEntriesFromDictionary:attributes];
        status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    }
    return checkStatus(status, error);
}

BOOL TVRemoveSigningIdentity(NSError **error) {
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)identityQuery());
    return checkStatus(status == errSecItemNotFound ? errSecSuccess : status, error);
}
