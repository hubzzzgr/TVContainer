#import <Foundation/Foundation.h>

void TVCrashLoggingStart(NSURL *root, NSString *context);
void TVCrashRecordException(NSException *exception);
NSArray<NSDictionary *> *TVCrashReports(void);
void TVCrashDeleteReports(void);
