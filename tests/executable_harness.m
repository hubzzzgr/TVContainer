#import <Foundation/Foundation.h>
#import "../TVContainer/Installer/TVExecutable.h"
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSError *error = TVPrepareExecutable([NSURL fileURLWithPath:@(argv[1])], atoi(argv[2]) != 0, 0x1b0200);
        if (error) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
        return 0;
    }
}
