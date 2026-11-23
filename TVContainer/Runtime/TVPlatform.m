#import "TVPlatform.h"
#import <Security/Security.h>
#import "../../LiveContainer/UIKitPrivate.h"
#import "../../LiveContainer/utils.h"
#include <signal.h>

BOOL TVRelaunch(void (^completion)(NSError *)) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (![workspaceClass respondsToSelector:@selector(defaultWorkspace)]) return NO;
    LSApplicationWorkspace *workspace = [workspaceClass defaultWorkspace];
    BOOL configurationAPI = [workspace respondsToSelector:@selector(openApplicationWithBundleIdentifier:configuration:completionHandler:)];
    BOOL usingConfigurationAPI = [workspace respondsToSelector:@selector(openApplicationWithBundleIdentifier:usingConfiguration:completionHandler:)];
    if (!configurationAPI && !usingConfigurationAPI) return NO;
    NSString *bundleID = NSUserDefaults.lcMainBundle.bundleIdentifier;
    __block NSUInteger failures = 0;
    void (^handler)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!success) {
                if (++failures == 2) completion(error ?: [NSError errorWithDomain:@"TVContainer" code:1 userInfo:@{NSLocalizedDescriptionKey: @"tvOS refused the relaunch request. Close and reopen TVContainer to launch the selected app."}]);
                return;
            }
            // Queue both open requests before terminating, as in upstream's
            // foreground relaunch sequence. Enter the guest before UIKit starts.
            [NSUserDefaults.lcUserDefaults synchronize];
            kill(getpid(), SIGKILL);
        });
    };
    for (NSUInteger attempt = 0; attempt < 2; attempt++) {
        _LSOpenConfiguration *configuration = [NSClassFromString(@"_LSOpenConfiguration") new];
        if (configurationAPI) [workspace openApplicationWithBundleIdentifier:bundleID configuration:configuration completionHandler:handler];
        else [workspace openApplicationWithBundleIdentifier:bundleID usingConfiguration:configuration completionHandler:handler];
    }
    return YES;
}

NSURL *TVStorageRoot(void) {
    const char *hostHome = getenv("LC_HOST_HOME_PATH") ?: getenv("HOME");
    return [NSURL fileURLWithPath:[NSString stringWithFormat:@"%s/Library/Caches/TVContainer", hostHome] isDirectory:YES];
}

NSString *TVTopShelfLaunchFolder(NSURL *url) {
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (![parts.scheme.lowercaseString isEqualToString:@"tvcontainer"] ||
        ![parts.host isEqualToString:@"top-shelf"] || parts.path.length ||
        parts.user || parts.password || parts.port || parts.fragment || parts.queryItems.count != 1) return nil;
    NSURLQueryItem *item = parts.queryItems.firstObject;
    NSString *folder = item.value;
    if (![item.name isEqualToString:@"app"] || ![folder.pathExtension isEqualToString:@"app"] ||
        ![[NSUUID alloc] initWithUUIDString:folder.stringByDeletingPathExtension]) return nil;
    return folder;
}

void TVLaunchGuestFolder(NSString *folder, void (^completion)(NSError *)) {
    if (![folder.lastPathComponent isEqualToString:folder] || ![folder.pathExtension isEqualToString:@"app"]) {
        completion([NSError errorWithDomain:@"TVContainer" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid app path."}]);
        return;
    }
    NSURL *apps = [TVStorageRoot() URLByAppendingPathComponent:@"Documents/Applications" isDirectory:YES];
    NSURL *app = [apps URLByAppendingPathComponent:folder isDirectory:YES];
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfURL:[app URLByAppendingPathComponent:@"LCAppInfo.plist"]];
    NSString *container = metadata[@"LCDataUUID"];
    if (![container isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:container]) {
        completion([NSError errorWithDomain:@"TVContainer" code:1 userInfo:@{NSLocalizedDescriptionKey: @"The app or its container is missing. Reinstall it from its URL."}]);
        return;
    }
    if ([NSUserDefaults.guestAppInfo[@"LCDataUUID"] isEqual:container]) return;
    NSUserDefaults *defaults = NSUserDefaults.lcUserDefaults ?: NSUserDefaults.standardUserDefaults;
    [defaults setObject:folder forKey:@"selected"];
    [defaults setObject:container forKey:@"selectedContainer"];
    [defaults synchronize];
    if (!TVRelaunch(completion)) {
        completion([NSError errorWithDomain:@"TVContainer" code:1 userInfo:@{NSLocalizedDescriptionKey: @"tvOS could not relaunch TVContainer. Close and reopen it to launch the selected guest."}]);
    }
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

BOOL TVSaveSigningIdentityIfAbsent(NSData *certificate, NSString *password, NSError **error) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"certificate": certificate, @"password": password}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data) return NO;
    NSMutableDictionary *query = identityQuery().mutableCopy;
    query[(__bridge id)kSecValueData] = data;
    query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    // A TCP import must never update an existing identity, including a race
    // with a different importer between validation and this Keychain call.
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    if (status == errSecDuplicateItem) {
        if (error) *error = [NSError errorWithDomain:@"TVContainer" code:status
            userInfo:@{NSLocalizedDescriptionKey:@"A signing certificate is already installed. It was not replaced."}];
        return NO;
    }
    return checkStatus(status, error);
}
