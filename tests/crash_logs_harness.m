#import <Foundation/Foundation.h>
#import "../TVContainer/Runtime/TVCrashLogs.h"
#include <signal.h>
#include <unistd.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 3) {
            TVCrashLoggingStart([NSURL fileURLWithPath:@(argv[1])], @"Disposable test guest");
            if (!strcmp(argv[2], "signal")) raise(SIGSEGV);
            @try { [NSException raise:@"TestException" format:@"Disposable test reason"]; }
            @catch (NSException *exception) { TVCrashRecordException(exception); }
            return 0;
        }
        NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
#if DEBUG
        for (NSString *mode in @[@"signal", @"exception"]) {
            NSTask *child = [NSTask new];
            child.executableURL = [NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments[0]];
            child.arguments = @[root.path, mode];
            NSError *error;
            NSCAssert([child launchAndReturnError:&error], @"%@", error);
            [child waitUntilExit];
            NSCAssert([mode isEqualToString:@"signal"] ? child.terminationReason == NSTaskTerminationReasonUncaughtSignal : child.terminationStatus == 0, @"Unexpected child result");
        }
        TVCrashLoggingStart(root, @"Test launcher");
        NSArray *reports = TVCrashReports();
        NSCAssert(reports.count == 2, @"Expected both crash reports: %@", reports);
        NSCAssert([[reports valueForKey:@"body"] componentsJoinedByString:@"\n"].length > 0, @"No report text");
        NSString *text = [[reports valueForKey:@"body"] componentsJoinedByString:@"\n"];
        NSCAssert([text containsString:@"Signal: 11"] && [text containsString:@"TestException: Disposable test reason"] && [text containsString:@"Call stack:"], @"Missing crash details");
        TVCrashDeleteReports();
        NSCAssert(TVCrashReports().count == 0, @"Clear failed");
        puts("Debug crash logs passed: fatal child signal, exception stack, restart history and deletion.");
#else
        TVCrashLoggingStart(root, @"Release launcher");
        TVCrashRecordException([NSException exceptionWithName:@"Test" reason:@"Test" userInfo:nil]);
        NSCAssert(TVCrashReports().count == 0 && ![NSFileManager.defaultManager fileExistsAtPath:root.path], @"Release wrote crash history");
        puts("Release crash logger is inactive.");
#endif
        [NSFileManager.defaultManager removeItemAtURL:root error:nil];
    }
    return 0;
}
