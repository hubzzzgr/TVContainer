#import <Foundation/Foundation.h>
#import "../TVContainer/Runtime/TVGuestBundle.h"
#include <dlfcn.h>
#include <assert.h>

static void verifyProbe(void *handle, NSBundle *guest) {
    assert(handle);
    CFBundleRef (*getCF)(void) = dlsym(handle, "ProbeMainCFBundle");
    NSBundle *(*getNS)(void) = dlsym(handle, "ProbeMainNSBundle");
    NSString *(*getResource)(void) = dlsym(handle, "ProbeResource");
    assert(getCF && getNS && getResource);
    assert(getNS() == guest);
    assert(CFEqual(CFBundleGetIdentifier(getCF()), CFSTR("org.tvcontainer.test-guest")));
    assert([getResource() isEqualToString:@"guest resource"]);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 3);
        void *before = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
        assert(before);
        NSBundle *host = NSBundle.mainBundle;
        NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        NSURL *path = [root URLByAppendingPathComponent:@"Guest.bundle"];
        NSFileManager *fm = NSFileManager.defaultManager;
        assert([fm createDirectoryAtURL:path withIntermediateDirectories:YES attributes:nil error:nil]);
        assert([@{@"CFBundleIdentifier": @"org.tvcontainer.test-guest", @"CFBundleName": @"Guest"}
            writeToURL:[path URLByAppendingPathComponent:@"Info.plist"] error:nil]);
        assert([@"guest resource" writeToURL:[path URLByAppendingPathComponent:@"marker.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        NSBundle *guest = [NSBundle bundleWithURL:path];
        assert(guest && guest != host);
        assert(!TVInstallGuestBundle(guest));
        assert(NSBundle.mainBundle == guest);
        verifyProbe(before, guest); // Already-bound imports must change too.
        void *after = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
        verifyProbe(after, guest); // Newly-loaded guest constructors see the guest.
        assert(!TVInstallGuestBundle(guest));
        assert(TVInstallGuestBundle(host)); // Never silently switch to another guest.
        assert(NSBundle.mainBundle == guest);
        [fm removeItemAtURL:root error:nil];
        puts("Bundle hooks passed: Foundation, CoreFoundation, resources, existing and future images, idempotence.");
    }
    return 0;
}
