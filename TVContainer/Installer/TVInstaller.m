#import "TVInstaller.h"
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

// Check every load command before passing downloaded bytes to upstream patchers.
static NSError *validateExecutable(NSURL *url, BOOL mainExecutable) {
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    if (data.length < sizeof(struct mach_header_64)) return TVError(@"The app contains a truncated executable.");
    const struct mach_header_64 *header = data.bytes;
    if (header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64)
        return TVError(@"TVContainer requires thin arm64 tvOS binaries. Export the app for Apple TV devices.");
    if (header->sizeofcmds > data.length - sizeof(*header)) return TVError(@"Invalid Mach-O load commands.");
    NSUInteger cursor = sizeof(*header), end = cursor + header->sizeofcmds;
    BOOL television = NO, entry = NO;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cursor > end || end - cursor < sizeof(struct load_command)) return TVError(@"Truncated Mach-O load command.");
        const struct load_command *cmd = data.bytes + cursor;
        if (cmd->cmdsize < sizeof(*cmd) || cmd->cmdsize > end - cursor) return TVError(@"Invalid Mach-O load command size.");
        if (cmd->cmd == LC_BUILD_VERSION && cmd->cmdsize >= sizeof(struct build_version_command)) {
            const struct build_version_command *build = (const void *)cmd;
            television = build->platform == PLATFORM_TVOS;
            if (build->minos > NSProcessInfo.processInfo.operatingSystemVersion.majorVersion * 0x10000 + NSProcessInfo.processInfo.operatingSystemVersion.minorVersion * 0x100)
                return TVError(@"This app needs a newer version of tvOS.");
        }
        if (cmd->cmd == LC_VERSION_MIN_TVOS) television = YES;
        if (cmd->cmd == LC_MAIN && cmd->cmdsize >= sizeof(struct entry_point_command)) entry = YES;
        if ((cmd->cmd == LC_ENCRYPTION_INFO_64 || cmd->cmd == LC_ENCRYPTION_INFO) &&
            cmd->cmdsize >= sizeof(struct encryption_info_command) && ((const struct encryption_info_command *)cmd)->cryptid)
            return TVError(@"Encrypted App Store apps cannot be hosted. Use a decrypted tvOS IPA.");
        cursor += cmd->cmdsize;
    }
    if (!television) return TVError(@"This is not a tvOS device app. iOS and simulator apps need to be rebuilt for Apple TV; changing their platform does not supply missing frameworks.");
    if (mainExecutable && (!entry || header->filetype != MH_EXECUTE)) return TVError(@"The app has no supported executable entry point.");
    return nil;
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

+ (void)installArchive:(NSURL *)archive completion:(void (^)(NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *stage = [fm.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        NSError *error = nil;
        [fm createDirectoryAtURL:stage withIntermediateDirectories:YES attributes:nil error:&error];
        if (!error && extract(archive.path, stage.path, [NSProgress progressWithTotalUnitCount:0])) error = TVError(@"Unable to extract this IPA.");
        NSArray<NSURL *> *items = [fm contentsOfDirectoryAtURL:[stage URLByAppendingPathComponent:@"Payload"] includingPropertiesForKeys:nil options:0 error:nil];
        NSMutableArray<NSURL *> *apps = [NSMutableArray new];
        for (NSURL *item in items) if ([item.pathExtension isEqualToString:@"app"]) [apps addObject:item];
        if (!error && apps.count != 1) error = TVError(@"The IPA must contain exactly one app in Payload.");
        NSURL *app = apps.firstObject ?: stage;
        NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfURL:[app URLByAppendingPathComponent:@"Info.plist"]];
        NSString *executable = info[@"CFBundleExecutable"], *identifier = info[@"CFBundleIdentifier"];
        if (!error && (!executable.length || !identifier.length || ![executable.lastPathComponent isEqualToString:executable])) error = TVError(@"The IPA has an invalid Info.plist.");
        NSURL *binary = [app URLByAppendingPathComponent:executable ?: @""];
        if (!error) error = validateExecutable(binary, YES);
        // Reject incompatible embedded libraries before changing or signing anything.
        for (NSURL *file in error ? @[] : [fm enumeratorAtURL:app includingPropertiesForKeys:nil options:0 errorHandler:nil]) {
            if (error) break;
            NSData *prefix = [NSData dataWithContentsOfURL:file options:NSDataReadingMappedIfSafe error:nil];
            if (prefix.length < 4) continue;
            uint32_t magic = *(const uint32_t *)prefix.bytes;
            if (magic == MH_MAGIC_64 || magic == FAT_CIGAM) error = validateExecutable(file, [file isEqual:binary]);
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
        [defaults removeObjectForKey:@"selected"];
        [defaults removeObjectForKey:@"selectedContainer"];
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
