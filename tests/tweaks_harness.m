#import <Foundation/Foundation.h>
#import "../TVContainer/Runtime/TVGuestTweaks.h"
#include <dlfcn.h>
#include <assert.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 2);
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *root = [fm.temporaryDirectory URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"app"]];
        NSURL *tweaks = [root URLByAppendingPathComponent:@"Tweaks"];
        NSURL *frameworks = [root URLByAppendingPathComponent:@"Frameworks"];
        assert([fm createDirectoryAtURL:tweaks withIntermediateDirectories:YES attributes:nil error:nil]);
        assert([fm createDirectoryAtURL:frameworks withIntermediateDirectories:YES attributes:nil error:nil]);
        [@{@"CFBundleIdentifier":@"org.test.guest", @"CFBundleExecutable":@"Guest"} writeToURL:[root URLByAppendingPathComponent:@"Info.plist"] atomically:YES];
        NSURL *probe = [tweaks URLByAppendingPathComponent:@"Probe.dylib"];
        assert([fm copyItemAtURL:[NSURL fileURLWithPath:@(argv[1])] toURL:probe error:nil]);
        [@{@"Filter":@{@"Bundles":@[@"org.test.guest"]}} writeToURL:[tweaks URLByAppendingPathComponent:@"Probe.plist"] atomically:YES];
        NSData *invalid = [@"not a library" dataUsingEncoding:NSUTF8StringEncoding];
        [invalid writeToURL:[tweaks URLByAppendingPathComponent:@"OtherApp.dylib"] atomically:YES];
        [@{@"Filter":@{@"Bundles":@[@"org.other.app"]}} writeToURL:[tweaks URLByAppendingPathComponent:@"OtherApp.plist"] atomically:YES];
        [invalid writeToURL:[frameworks URLByAppendingPathComponent:@"Optional.dylib"] atomically:YES];
        NSBundle *guest = [NSBundle bundleWithURL:root];
        assert(guest);
        assert(!TVLoadGuestTweaks(guest));
        assert(!TVLoadGuestTweaks(guest));
        void *handle = dlopen(probe.fileSystemRepresentation, RTLD_NOW);
        int (*count)(void) = dlsym(handle, "TVTweakProbeCount");
        assert(count && count() == 1);
        [invalid writeToURL:[tweaks URLByAppendingPathComponent:@"Broken.dylib"] atomically:YES];
        assert([TVLoadGuestTweaks(guest) containsString:@"Broken.dylib"]);
        [fm removeItemAtURL:root error:nil];
        puts("Bundled tweak tests passed: constructors, filters, optional libraries, duplicate initialization, diagnostics.");
    }
}
