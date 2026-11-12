#import <Foundation/Foundation.h>
#import "TVPlatform.h"
#include <assert.h>
int main(void) {
    @autoreleasepool {
        assert(!TVReadSigningIdentity());
        NSData *first = [@"first fixture" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *second = [@"second fixture" dataUsingEncoding:NSUTF8StringEncoding];
        __block int successes = 0;
        NSLock *lock = [NSLock new];
        dispatch_group_t group = dispatch_group_create();
        for (NSData *candidate in @[first, second]) {
            dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                NSError *error = nil;
                BOOL result = TVSaveSigningIdentityIfAbsent(candidate, @"fixture password", &error);
                [lock lock]; successes += result; [lock unlock];
            });
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        assert(successes == 1);
        NSDictionary *stored = TVReadSigningIdentity();
        assert(stored && [stored[@"password"] isEqual:@"fixture password"]);
        NSError *error = nil;
        assert(!TVSaveSigningIdentityIfAbsent(second, @"replacement", &error));
        assert(error && [stored isEqual:TVReadSigningIdentity()]);
        assert(TVRemoveSigningIdentity(nil));
        assert(!TVReadSigningIdentity());
        puts("Signing-store tests passed: one winner under concurrent insert, existing certificate and password preserved, cleanup.");
    }
}
