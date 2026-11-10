#import "TVGuestBundle.h"
#import "../../litehook/src/litehook.h"
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <mach/mach.h>

static NSBundle *guestBundle;
static CFBundleRef guestCFBundle;
static BOOL installed;

static NSBundle *TVMainNSBundle(id receiver, SEL selector) { return guestBundle; }
static CFBundleRef TVMainCFBundle(void) { return guestCFBundle; }

static void updateCFCacheIfAvailable(CFBundleRef original, CFBundleRef replacement) {
    // Shared-cache symbols may be absent on a device. Never infer this address
    // from adjacent TBZ/TBNZ/ADRP instructions, or write an unvalidated pointer.
#if TV_BUNDLE_TEST_NO_CACHE
    void *slot = NULL;
#else
    void *slot = litehook_find_dsc_symbol("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", "__mainBundle");
#endif
    if (!slot) return;
    CFBundleRef current = NULL;
    vm_size_t read = 0;
    if (vm_read_overwrite(mach_task_self(), (vm_address_t)slot, sizeof(current),
                         (vm_address_t)&current, &read) != KERN_SUCCESS ||
        read != sizeof(current) || current != original) return;
    // This can fail on protected memory. The imported-function hook below is
    // the fallback; no code-page protection changes are needed in JIT-less mode.
    vm_write(mach_task_self(), (vm_address_t)slot, (vm_offset_t)&replacement, sizeof(replacement));
}

NSString *TVInstallGuestBundle(NSBundle *bundle) {
    if (installed) return guestBundle == bundle ? nil : @"A different guest bundle is already active in this process.";
    if (!bundle.bundleURL) return @"The guest bundle has no resource URL.";
    CFBundleRef newCFBundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)bundle.bundleURL);
    if (!newCFBundle) return @"Unable to create the guest's CoreFoundation bundle.";
    Method method = class_getClassMethod(NSBundle.class, @selector(mainBundle));
    if (!method) { CFRelease(newCFBundle); return @"Foundation's main bundle accessor is unavailable."; }
    CFBundleRef original = CFBundleGetMainBundle();
    guestBundle = bundle;
    guestCFBundle = newCFBundle; // Retain until process exit, including guest constructors.
    updateCFCacheIfAvailable(original, guestCFBundle);
    class_replaceMethod(object_getClass(NSBundle.class), @selector(mainBundle),
                        (IMP)TVMainNSBundle, method_getTypeEncoding(method));
    // Existing imports and future dlopen images are rebound by litehook. Its
    // source image is excluded, so the runtime retains its original CF accessor.
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, CFBundleGetMainBundle, TVMainCFBundle, NULL);
    if (NSBundle.mainBundle != bundle) return @"Unable to install the guest's Foundation bundle accessor.";
    installed = YES;
    return nil;
}
