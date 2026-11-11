#import "TVGuestTweaks.h"
#include <dlfcn.h>

static BOOL matchesFilter(NSDictionary *filter, NSBundle *guest) {
    if (!filter) return YES;
    NSMutableArray<NSNumber *> *matches = [NSMutableArray new];
    for (NSString *key in @[@"Bundles", @"Executables", @"Classes"]) {
        NSArray *values = filter[key];
        if (![values isKindOfClass:NSArray.class]) continue;
        BOOL match = NO;
        for (id value in values) {
            if (![value isKindOfClass:NSString.class]) continue;
            if ([key isEqual:@"Bundles"]) match |= [value isEqual:guest.bundleIdentifier];
            else if ([key isEqual:@"Executables"]) match |= [value isEqual:guest.infoDictionary[@"CFBundleExecutable"]];
            else match |= NSClassFromString(value) != Nil;
        }
        [matches addObject:@(match)];
    }
    if (!matches.count) return NO; // Do not ignore an unknown filter.
    if ([filter[@"Mode"] isEqual:@"Any"]) return [matches containsObject:@YES];
    return ![matches containsObject:@NO];
}

NSString *TVLoadGuestTweaks(NSBundle *guest) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *errors = [NSMutableArray new];
    for (NSString *directory in @[@"Tweaks", @"Dylibs", @"Frameworks"]) {
        NSURL *root = [guest.bundleURL URLByAppendingPathComponent:directory];
        NSArray<NSURL *> *files = [[fm contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0 error:nil]
            sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [a.path compare:b.path]; }];
        for (NSURL *file in files) {
            if (![file.pathExtension isEqual:@"dylib"] || [file.lastPathComponent isEqual:@"TweakLoader.dylib"]) continue;
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfURL:[[file URLByDeletingPathExtension] URLByAppendingPathExtension:@"plist"]];
            NSDictionary *filter = [plist[@"Filter"] isKindOfClass:NSDictionary.class] ? plist[@"Filter"] : nil;
            // Frameworks can contain optional app libraries; only explicitly
            // filtered tweaks belong in this scan. Existing LC_LOAD commands
            // continue to load injected libraries through dyld normally.
            if ([directory isEqual:@"Frameworks"] && !filter) continue;
            if (!matchesFilter(filter, guest)) continue;
            dlerror();
            void *handle = dlopen(file.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
            if (!handle) {
                const char *reason = dlerror();
                [errors addObject:[NSString stringWithFormat:@"%@: %s", file.lastPathComponent, reason ?: "Unknown loader error"]];
            }
        }
    }
    if (!errors.count) return nil;
    return [@"Unable to load bundled tweaks:\n" stringByAppendingString:[errors componentsJoinedByString:@"\n"]];
}
