#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "../../LiveContainer/UIKitPrivate.h"
#import "../../LiveContainer/utils.h"
#import "../Runtime/TVPlatform.h"

static BOOL openTopShelfURL(NSURL *url) {
    NSString *folder = TVTopShelfLaunchFolder(url);
    if (!folder) return NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        TVLaunchGuestFolder(folder, ^(NSError *error) {
            if (error) [NSUserDefaults.lcUserDefaults setObject:error.localizedDescription forKey:@"error"];
        });
    });
    return YES;
}

// The launcher handles URLs in SwiftUI. While a guest owns UIKit, intercept
// only Top Shelf actions at the same entry points as upstream's guest hooks.
@implementation UIApplication (TVTopShelfGuestLinks)
- (void)tv_topShelfOpenAction:(id)action payload:(NSDictionary *)payload origin:(id)origin {
    id value = payload[UIApplicationLaunchOptionsURLKey];
    NSURL *url = [value isKindOfClass:NSString.class] ? [NSURL URLWithString:value] :
        ([value isKindOfClass:NSURL.class] ? value : nil);
    if (!url || !openTopShelfURL(url)) [self tv_topShelfOpenAction:action payload:payload origin:origin];
}
@end

@implementation UIScene (TVTopShelfGuestLinks)
- (void)tv_topShelfScene:(id)scene didReceiveActions:(NSSet *)actions fromTransitionContext:(id)context {
    NSMutableSet *remaining = nil;
    Class urlActionClass = NSClassFromString(@"UIOpenURLAction");
    for (id action in actions) {
        if ([action isKindOfClass:urlActionClass] && openTopShelfURL([(UIOpenURLAction *)action url])) {
            if (!remaining) remaining = actions.mutableCopy;
            [remaining removeObject:action];
        }
    }
    if (!remaining || remaining.count) {
        [self tv_topShelfScene:scene didReceiveActions:remaining ?: actions fromTransitionContext:context];
    }
}
@end

__attribute__((constructor)) static void installTopShelfGuestLinks(void) {
    if (!NSUserDefaults.lcGuestAppId) return;
    Method appMethod = class_getInstanceMethod(UIApplication.class, @selector(_applicationOpenURLAction:payload:origin:));
    Method sceneMethod = class_getInstanceMethod(UIScene.class, @selector(scene:didReceiveActions:fromTransitionContext:));
    if (appMethod) method_exchangeImplementations(appMethod,
        class_getInstanceMethod(UIApplication.class, @selector(tv_topShelfOpenAction:payload:origin:)));
    if (sceneMethod) method_exchangeImplementations(sceneMethod,
        class_getInstanceMethod(UIScene.class, @selector(tv_topShelfScene:didReceiveActions:fromTransitionContext:)));
}
