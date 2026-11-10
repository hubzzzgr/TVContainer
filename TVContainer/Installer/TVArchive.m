#import "TVArchive.h"
#import "../../LiveContainerSwiftUI/Utilities/unarchive.h"

static NSURL *archiveError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"TVContainer.Archive" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
    return nil;
}

NSURL *TVExtractAppArchive(NSURL *archive, NSURL *stage, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *input = archive;
    // Detect the contents, never the URL extension or the download's temporary
    // filename. An IPA is itself a ZIP containing Payload/<app>.app.
    for (NSUInteger layer = 0; layer < 2; layer++) {
        NSURL *output = [stage URLByAppendingPathComponent:[NSString stringWithFormat:@"extracted-%lu", (unsigned long)layer] isDirectory:YES];
        if (![fm createDirectoryAtURL:output withIntermediateDirectories:YES attributes:nil error:error]) return nil;
        if (extract(input.path, output.path, [NSProgress progressWithTotalUnitCount:0]))
            return archiveError(error, @"Unable to read the app archive. Use a direct IPA download URL or a ZIP containing one IPA, rather than a web download page.");
        NSURL *payload = [output URLByAppendingPathComponent:@"Payload" isDirectory:YES];
        if ([fm fileExistsAtPath:payload.path]) {
            NSArray<NSURL *> *items = [fm contentsOfDirectoryAtURL:payload includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:error];
            if (!items) return nil;
            NSMutableArray<NSURL *> *apps = [NSMutableArray new];
            for (NSURL *item in items) {
                NSNumber *directory = nil;
                [item getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
                if (directory.boolValue && [item.pathExtension.lowercaseString isEqualToString:@"app"]) [apps addObject:item];
            }
            if (apps.count != 1) return archiveError(error, @"The IPA must contain exactly one app in Payload.");
            return apps.firstObject;
        }
        if (layer == 1) break;
        NSMutableArray<NSURL *> *ipas = [NSMutableArray new];
        for (NSURL *item in [fm enumeratorAtURL:output includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil]) {
            if ([item.pathComponents containsObject:@"__MACOSX"]) continue;
            NSNumber *regular = nil;
            [item getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
            if (regular.boolValue && [item.pathExtension.lowercaseString isEqualToString:@"ipa"]) [ipas addObject:item];
        }
        if (ipas.count != 1) return archiveError(error, @"The download must be an IPA, or a ZIP containing exactly one IPA.");
        input = ipas.firstObject;
    }
    return archiveError(error, @"The enclosed IPA has no Payload app. Only one outer ZIP wrapper is supported.");
}
