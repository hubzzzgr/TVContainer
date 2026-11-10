#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "../../LiveContainer/utils.h"
#import "../Runtime/TVPlatform.h"

// Preserve native guest focus and Back/Select behavior. Only a long Play/Pause
// press returns to the library; UIKit routes normal presses to the guest.
@interface TVRemoteReturn : NSObject
+ (instancetype)shared;
- (void)returnToLibrary:(UILongPressGestureRecognizer *)gesture;
@end
@implementation TVRemoteReturn
+ (instancetype)shared {
    static TVRemoteReturn *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [TVRemoteReturn new]; });
    return instance;
}
- (void)returnToLibrary:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    [NSUserDefaults.lcUserDefaults setObject:@"ui" forKey:@"selected"];
    [NSUserDefaults.lcUserDefaults removeObjectForKey:@"selectedContainer"];
    [NSUserDefaults.lcUserDefaults synchronize];
    TVRelaunch(^(NSError *error) {
        [NSUserDefaults.lcUserDefaults removeObjectForKey:@"selected"];
        [NSUserDefaults.lcUserDefaults synchronize];
        UIViewController *presenter = gesture.view.window.rootViewController;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TVContainer"
            message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}
@end
static void addReturnGesture(UIWindow *window) {
    if (objc_getAssociatedObject(window, @selector(tv_makeKeyAndVisible))) return;
    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc] initWithTarget:TVRemoteReturn.shared action:@selector(returnToLibrary:)];
    gesture.allowedPressTypes = @[@(UIPressTypePlayPause)];
    gesture.minimumPressDuration = 2;
    gesture.cancelsTouchesInView = NO;
    [window addGestureRecognizer:gesture];
    objc_setAssociatedObject(window, @selector(tv_makeKeyAndVisible), gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@implementation UIWindow(TVContainerRemote)
- (void)tv_makeKeyAndVisible {
    addReturnGesture(self);
    [self tv_makeKeyAndVisible];
}
@end
__attribute__((constructor)) static void installTVRemoteHooks(void) {
    method_exchangeImplementations(class_getInstanceMethod(UIWindow.class, @selector(makeKeyAndVisible)),
                                   class_getInstanceMethod(UIWindow.class, @selector(tv_makeKeyAndVisible)));
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
            if ([scene isKindOfClass:UIWindowScene.class])
                for (UIWindow *window in ((UIWindowScene *)scene).windows) addReturnGesture(window);
    });
}
