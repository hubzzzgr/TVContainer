#import <Foundation/Foundation.h>
#import "../TVContainer/Installer/TVArchive.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSError *error = nil;
        NSURL *app = TVExtractAppArchive([NSURL fileURLWithPath:@(argv[1])], [NSURL fileURLWithPath:@(argv[2])], &error);
        if (!app) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
        puts(app.path.UTF8String);
        return 0;
    }
}
