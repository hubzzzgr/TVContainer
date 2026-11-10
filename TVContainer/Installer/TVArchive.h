#import <Foundation/Foundation.h>

// Accept an IPA's Payload directly, or one IPA inside an outer ZIP. The caller
// owns the staging directory and removes it after signing or failure.
NSURL *TVExtractAppArchive(NSURL *archive, NSURL *stage, NSError **error);
