#import <Foundation/Foundation.h>
#import "../LiveContainerSwiftUI/Utilities/unarchive.h"
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        return extract(@(argv[1]), @(argv[2]), [NSProgress progressWithTotalUnitCount:0]);
    }
}
