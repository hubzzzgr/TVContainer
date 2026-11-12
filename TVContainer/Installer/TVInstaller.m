#import "TVInstaller.h"
#import "TVArchive.h"
#import "TVMachOSlice.h"
#import "TVExecutable.h"
#import "../Runtime/TVPlatform.h"
#import "../../LiveContainer/LCMachOUtils.h"
#import "../../LiveContainer/LCSharedUtils.h"
#import "../../ZSign/zsigner.h"
#import "../../LiveContainerSwiftUI/Utilities/unarchive.h"
#include <mach-o/loader.h>
#include <mach-o/fat.h>

static NSError *TVError(NSString *message) {
    return [NSError errorWithDomain:@"TVContainer" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation TVInstaller
+ (NSURL *)applicationsURL {
    return [TVStorageRoot() URLByAppendingPathComponent:@"Documents/Applications" isDirectory:YES];
}
+ (BOOL)hasCertificate { return TVReadSigningIdentity()[@"certificate"] != nil; }
+ (BOOL)importCertificate:(NSData *)data password:(NSString *)password error:(NSError **)error {
    if (!data.length || data.length > 4 * 1024 * 1024 || ![ZSigner getTeamIdWithCert:data pass:password].length) {
        if (error) *error = TVError(@"Unable to read this signing identity. Check the P12 certificate and password.");
        return NO;
    }
    NSString *hostTeam = LCSharedUtils.teamIdentifier;
    NSString *certTeam = [ZSigner getTeamIdWithCert:data pass:password];
    if (hostTeam.length && ![hostTeam isEqualToString:certTeam]) {
        if (error) *error = TVError(@"The certificate must belong to the same Apple Developer team that signed TVContainer.");
        return NO;
    }
    return TVSaveSigningIdentity(data, password, error);
}
+ (BOOL)removeCertificateWithError:(NSError **)error { return TVRemoveSigningIdentity(error); }

+ (BOOL)importCertificateIfAbsent:(NSData *)data password:(NSString *)password error:(NSError **)error {
    if (self.hasCertificate) {
        if (error) *error = TVError(@"A signing certificate is already installed. It was not replaced.");
        return NO;
    }
    if (!data.length || data.length > 4 * 1024 * 1024) {
        if (error) *error = TVError(@"Invalid P12 signing identity.");
        return NO;
    }
    NSString *team = [ZSigner getTeamIdWithCert:data pass:password];
    if (!team.length) {
        if (error) *error = TVError(@"Unable to read this signing identity. Check the P12 file and password.");
        return NO;
    }
    if (LCSharedUtils.teamIdentifier.length && ![team isEqualToString:LCSharedUtils.teamIdentifier]) {
        if (error) *error = TVError(@"The certificate must belong to the Apple Developer team that signed TVContainer.");
        return NO;
    }
    return TVSaveSigningIdentityIfAbsent(data, password, error);
}

+ (void)incomingAppName:(NSURL *)archive completion:(void (^)(NSString *, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *stage = [fm.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        NSError *error = nil;
        [fm createDirectoryAtURL:stage withIntermediateDirectories:YES attributes:nil error:&error];
        NSURL *app = error ? nil : TVExtractAppArchive(archive, stage, &error);
        NSDictionary *info = app ? [NSDictionary dictionaryWithContentsOfURL:[app URLByAppendingPathComponent:@"Info.plist"]] : nil;
        NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
        if (![name isKindOfClass:NSString.class] || !name.length) name = app.lastPathComponent.stringByDeletingPathExtension;
        if (!error && !info) error = TVError(@"The IPA has no valid app Info.plist.");
        [fm removeItemAtURL:stage error:nil];
        completion(error ? nil : name, error);
    });
}

+ (void)installArchive:(NSURL *)archive completion:(void (^)(NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *stage = [fm.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        NSError *error = nil;
        [fm createDirectoryAtURL:stage withIntermediateDirectories:YES attributes:nil error:&error];
        NSURL *app = error ? nil : TVExtractAppArchive(archive, stage, &error);
        if (!app) {
            [fm removeItemAtURL:stage error:nil];
            completion(error ?: TVError(@"Unable to find an app in the download."));
            return;
        }
        NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfURL:[app URLByAppendingPathComponent:@"Info.plist"]];
        NSString *executable = info[@"CFBundleExecutable"], *identifier = info[@"CFBundleIdentifier"];
        if (![executable isKindOfClass:NSString.class]) executable = nil;
        if (![identifier isKindOfClass:NSString.class]) identifier = nil;
        if (!error && (!executable.length || !identifier.length || ![executable.lastPathComponent isEqualToString:executable])) error = TVError(@"The IPA has an invalid Info.plist.");
        NSURL *binary = [app URLByAppendingPathComponent:executable ?: @""];
        NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
        uint32_t version = (uint32_t)(os.majorVersion * 0x10000 + os.minorVersion * 0x100 + os.patchVersion);
        if (!error) error = TVPrepareExecutable(binary, YES, version);
        // Reject incompatible embedded libraries before changing or signing anything.
        for (NSURL *file in error ? @[] : [fm enumeratorAtURL:app includingPropertiesForKeys:nil options:0 errorHandler:nil]) {
            if (error) break;
            NSData *prefix = [NSData dataWithContentsOfURL:file options:NSDataReadingMappedIfSafe error:nil];
            if (prefix.length < 4) continue;
            if (TVIsMachO(prefix)) error = TVPrepareExecutable(file, [file isEqual:binary], version);
        }
        NSDictionary *identity = TVReadSigningIdentity();
        if (!error && !identity) error = TVError(@"Import your signing certificate from a URL in Settings first.");
        __block int patchResult = 0;
        if (!error) {
            NSString *message = LCParseMachO(binary.fileSystemRepresentation, false, ^(const char *path, struct mach_header_64 *header, int fd, void *map) {
                patchResult = LCPatchExecSlice(path, header, false);
                LCChangeMachOUUID(header);
            });
            if (message) error = TVError(message);
            if (!error && (patchResult & PATCH_EXEC_RESULT_SEG_COUNT_MISMATCH))
                error = TVError(@"This executable has an incompatible chained-fixup layout. tvOS does not support the Mach exception workaround required to host it.");
        }
        // Native tvOS apps need neither the iPhone file picker shim nor rotation hooks.
        NSString *folder = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"app"];
        NSString *container = NSUUID.UUID.UUIDString;
        NSDictionary *metadata = @{@"LCDataUUID": container, @"LCOrignalBundleIdentifier": identifier ?: @"",
            @"LCContainers": @[@{@"folderName": container, @"name": @"Default"}],
            @"dontInjectTweakLoader": @YES, @"dontLoadTweakLoader": @NO,
            @"helperProcessesSupport": @NO, @"classicMode": @NO,
            @"segCountMismatch": @((patchResult & PATCH_EXEC_RESULT_SEG_COUNT_MISMATCH) != 0)};
        if (!error && ![metadata writeToURL:[app URLByAppendingPathComponent:@"LCAppInfo.plist"] error:&error]) {}
        if (error) {
            [fm removeItemAtURL:stage error:nil];
            completion(error);
            return;
        }
        [ZSigner signWithAppPath:app.path bundleId:NSBundle.mainBundle.bundleIdentifier cert:identity[@"certificate"] pass:identity[@"password"] completionHandler:^(BOOL success, NSError *signError) {
            NSError *result = signError;
            if (!success && !result) result = TVError(@"Signing failed.");
            if (!result) {
                [fm createDirectoryAtURL:self.applicationsURL withIntermediateDirectories:YES attributes:nil error:&result];
                if (!result) [fm moveItemAtURL:app toURL:[self.applicationsURL URLByAppendingPathComponent:folder] error:&result];
            }
            [fm removeItemAtURL:stage error:nil];
            completion(result);
        }];
    });
}

+ (void)launchApp:(NSString *)folder completion:(void (^)(NSError *))completion {
    if (![folder.lastPathComponent isEqualToString:folder]) { completion(TVError(@"Invalid app path.")); return; }
    NSURL *app = [self.applicationsURL URLByAppendingPathComponent:folder];
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfURL:[app URLByAppendingPathComponent:@"LCAppInfo.plist"]];
    if (!metadata[@"LCDataUUID"]) { completion(TVError(@"The app or its container is missing. Reinstall it from its URL.")); return; }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:folder forKey:@"selected"];
    [defaults setObject:metadata[@"LCDataUUID"] forKey:@"selectedContainer"];
    [defaults synchronize];
    if (!TVRelaunch(completion)) {
        completion(TVError(@"tvOS could not relaunch TVContainer. Close and reopen it to launch the selected guest."));
    }
}
+ (BOOL)removeApp:(NSString *)folder error:(NSError **)error {
    if (![folder.lastPathComponent isEqualToString:folder]) return NO;
    NSURL *app = [self.applicationsURL URLByAppendingPathComponent:folder];
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfURL:[app URLByAppendingPathComponent:@"LCAppInfo.plist"]];
    NSString *container = metadata[@"LCDataUUID"];
    if (![NSFileManager.defaultManager removeItemAtURL:app error:error]) return NO;
    if (container.length && [container.lastPathComponent isEqualToString:container]) {
        NSURL *data = [TVStorageRoot() URLByAppendingPathComponent:[@"Documents/Data/Application" stringByAppendingPathComponent:container]];
        if ([NSFileManager.defaultManager fileExistsAtPath:data.path]) return [NSFileManager.defaultManager removeItemAtURL:data error:error];
    }
    return YES;
}
@end
