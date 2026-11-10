#import <Foundation/Foundation.h>

// Install before guest initializers. Returns a launch error instead of asserting
// against an OS-specific instruction pattern.
NSString *TVInstallGuestBundle(NSBundle *bundle);
