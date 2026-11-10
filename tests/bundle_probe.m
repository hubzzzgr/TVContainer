#import <Foundation/Foundation.h>
CFBundleRef ProbeMainCFBundle(void) { return CFBundleGetMainBundle(); }
NSBundle *ProbeMainNSBundle(void) { return NSBundle.mainBundle; }
NSString *ProbeResource(void) {
    NSString *path = [NSBundle.mainBundle pathForResource:@"marker" ofType:@"txt"];
    return path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
}
