#import "TVInstaller.h"
#include <dlfcn.h>

@interface TVCoreUICatalog : NSObject
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
- (NSArray<NSString *> *)allImageNames;
@end

@implementation TVInstaller(IconCatalog)
+ (NSArray<NSString *> *)iconAssetNamesAtURL:(NSURL *)url {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_LAZY); });
    Class catalogClass = NSClassFromString(@"CUICatalog");
    if (![catalogClass instancesRespondToSelector:@selector(initWithURL:error:)] ||
        ![catalogClass instancesRespondToSelector:@selector(allImageNames)]) return @[];
    // Discovery is optional. Rendering still goes through UIKit's bundle-aware
    // image loader, which understands layered tvOS artwork.
    @try {
        TVCoreUICatalog *catalog = [[catalogClass alloc] initWithURL:[url URLByAppendingPathComponent:@"Assets.car"] error:nil];
        id names = catalog.allImageNames;
        if (![names isKindOfClass:NSArray.class]) return @[];
        NSMutableArray *result = [NSMutableArray new];
        for (id name in names)
            if ([name isKindOfClass:NSString.class] && [[name lowercaseString] containsString:@"icon"])
                [result addObject:name];
        return result;
    } @catch (NSException *exception) { return @[]; }
}
@end
