#import "TVCrashLogs.h"
#if DEBUG
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>

typedef struct { uint32_t magic; int32_t signal, code; uint32_t reserved; uint64_t address; } TVSignalRecord;
static int signalFile = -1;
static volatile sig_atomic_t recording;
static NSURL *directory, *currentMetadata;
static NSDictionary *launchMetadata;
static const int fatalSignals[] = {SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP};
static struct sigaction previousActions[6];

static void recordSignal(int number, siginfo_t *info, void *context) {
    if (!recording) {
        recording = 1;
        TVSignalRecord record = {0x54564352, number, info ? info->si_code : 0, 0, info ? (uintptr_t)info->si_addr : 0};
        // No Foundation, allocation, locks, or stack unwinding in a signal handler.
        if (signalFile >= 0) write(signalFile, &record, sizeof(record));
    }
    for (size_t i = 0; i < 6; i++) {
        if (fatalSignals[i] != number) continue;
        sigaction(number, &previousActions[i], NULL);
        if (previousActions[i].sa_flags & SA_SIGINFO) {
            if (previousActions[i].sa_sigaction) previousActions[i].sa_sigaction(number, info, context);
        } else if (previousActions[i].sa_handler != SIG_DFL && previousActions[i].sa_handler != SIG_IGN) {
            previousActions[i].sa_handler(number);
        }
        // Preserve fatal termination even if an earlier handler returns.
        signal(number, SIG_DFL);
        raise(number);
        return;
    }
    _exit(128 + number);
}

static void saveMetadata(NSDictionary *metadata, NSURL *url) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:metadata options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:url options:NSDataWritingAtomic error:nil];
}

NSArray<NSDictionary *> *TVCrashReports(void) {
    if (!directory) return @[];
    NSMutableArray *reports = [NSMutableArray new];
    for (NSURL *file in [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:nil]) {
        if (![file.pathExtension isEqualToString:@"json"]) continue;
        NSDictionary *metadata = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:file] ?: [NSData data] options:0 error:nil];
        if (![metadata isKindOfClass:NSDictionary.class]) continue;
        NSData *signalData = [NSData dataWithContentsOfURL:[[file URLByDeletingPathExtension] URLByAppendingPathExtension:@"signal"]];
        TVSignalRecord record = {0};
        BOOL hasSignal = signalData.length == sizeof(record);
        if (hasSignal) { [signalData getBytes:&record length:sizeof(record)]; hasSignal = record.magic == 0x54564352; }
        if (!hasSignal && !metadata[@"exception"]) continue;
        NSMutableString *body = [NSMutableString stringWithFormat:@"Date: %@\nApp: %@\nContext: %@\n", metadata[@"date"] ?: @"", metadata[@"version"] ?: @"", metadata[@"context"] ?: @""];
        if (hasSignal) [body appendFormat:@"\nSignal: %d (%s)\nCode: %d\nFault address: 0x%llx\n", record.signal, strsignal(record.signal) ?: "Unknown", record.code, (unsigned long long)record.address];
        if (metadata[@"exception"]) [body appendFormat:@"\n%@\n", metadata[@"exception"]];
        [reports addObject:@{@"id": file.lastPathComponent, @"date": metadata[@"date"] ?: @"", @"context": metadata[@"context"] ?: @"TVContainer", @"body": body}];
    }
    return [reports sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"date"] compare:a[@"date"]]; }];
}

void TVCrashDeleteReports(void) {
    for (NSDictionary *report in TVCrashReports()) {
        NSURL *metadata = [directory URLByAppendingPathComponent:report[@"id"]];
        if ([metadata isEqual:currentMetadata]) continue;
        [NSFileManager.defaultManager removeItemAtURL:metadata error:nil];
        [NSFileManager.defaultManager removeItemAtURL:[[metadata URLByDeletingPathExtension] URLByAppendingPathExtension:@"signal"] error:nil];
    }
}

void TVCrashLoggingStart(NSURL *root, NSString *context) {
    if (directory) return;
    directory = [root URLByAppendingPathComponent:@"CrashLogs" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
    // Keep a bounded history; remove clean, empty records from earlier launches.
    NSArray *reports = TVCrashReports();
    NSMutableSet *keep = [NSMutableSet new];
    for (NSDictionary *report in [reports subarrayWithRange:NSMakeRange(0, MIN(reports.count, 30))]) [keep addObject:report[@"id"]];
    for (NSURL *file in [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:nil]) {
        NSString *metadataName = [[[file URLByDeletingPathExtension] URLByAppendingPathExtension:@"json"] lastPathComponent];
        if (![keep containsObject:metadataName]) [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    }
    NSString *identifier = NSUUID.UUID.UUIDString;
    currentMetadata = [directory URLByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"json"]];
    launchMetadata = @{@"date": [NSISO8601DateFormatter.new stringFromDate:NSDate.date], @"context": context ?: @"TVContainer launcher",
        @"version": [NSString stringWithFormat:@"%@ (%@)", NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"", NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @""]};
    saveMetadata(launchMetadata, currentMetadata);
    NSURL *signalURL = [directory URLByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"signal"]];
    signalFile = open(signalURL.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (signalFile < 0) return;
    struct sigaction action = {0};
    action.sa_sigaction = recordSignal;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    for (size_t i = 0; i < 6; i++) sigaction(fatalSignals[i], &action, &previousActions[i]);
}

void TVCrashRecordException(NSException *exception) {
    if (!currentMetadata) return;
    NSMutableDictionary *metadata = launchMetadata.mutableCopy;
    metadata[@"exception"] = [NSString stringWithFormat:@"%@: %@\n\nCall stack:\n%@", exception.name, exception.reason ?: @"", [exception.callStackSymbols componentsJoinedByString:@"\n"]];
    saveMetadata(metadata, currentMetadata);
}
#else
void TVCrashLoggingStart(NSURL *root, NSString *context) {}
void TVCrashRecordException(NSException *exception) {}
NSArray<NSDictionary *> *TVCrashReports(void) { return @[]; }
void TVCrashDeleteReports(void) {}
#endif
