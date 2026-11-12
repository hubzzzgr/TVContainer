#import "TVReceiverDeviceInfo.h"
#include <dlfcn.h>

NSString *TVReceiverDeviceName(void) {
    // tvOS exposes SystemConfiguration but not all of its declarations in the
    // public SDK. Resolve the read-only computer-name accessor at runtime.
    CFStringRef (*copyName)(CFTypeRef, CFStringEncoding *) = dlsym(RTLD_DEFAULT, "SCDynamicStoreCopyComputerName");
    if (copyName) {
        id value = CFBridgingRelease(copyName(NULL, NULL));
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (gestalt) {
        CFTypeRef (*answer)(CFStringRef) = dlsym(gestalt, "MGCopyAnswer");
        id value = answer ? CFBridgingRelease(answer(CFSTR("UserAssignedDeviceName"))) : nil;
        dlclose(gestalt);
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return nil; // Never advertise a fabricated or generic device name.
}
