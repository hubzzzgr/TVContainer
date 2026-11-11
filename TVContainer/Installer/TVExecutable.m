#import "TVExecutable.h"
#import "TVMachOSlice.h"
#include <mach-o/loader.h>
static NSError *TVExecutableError(NSString *message) {
    return [NSError errorWithDomain:@"TVContainer" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
// Check every load command before passing downloaded bytes to upstream patchers.
NSError *TVPrepareExecutable(NSURL *url, BOOL mainExecutable, uint32_t systemVersion) {
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    NSError *sliceError = nil;
    NSData *original = data;
    data = TVArm64Slice(data, &sliceError);
    if (!data) return sliceError;
    if (data.length < sizeof(struct mach_header_64)) return TVExecutableError(@"The app contains a truncated executable.");
    const struct mach_header_64 *header = data.bytes;
    if (header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64)
        return TVExecutableError(@"The app contains a binary without a compatible arm64 tvOS device slice.");
    if (header->sizeofcmds > data.length - sizeof(*header)) return TVExecutableError(@"Invalid Mach-O load commands.");
    NSUInteger cursor = sizeof(*header), end = cursor + header->sizeofcmds;
    BOOL television = NO, entry = NO, text = NO;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cursor > end || end - cursor < sizeof(struct load_command)) return TVExecutableError(@"Truncated Mach-O load command.");
        const struct load_command *cmd = data.bytes + cursor;
        if (cmd->cmdsize < sizeof(*cmd) || cmd->cmdsize > end - cursor) return TVExecutableError(@"Invalid Mach-O load command size.");
        if (cmd->cmd == LC_BUILD_VERSION && cmd->cmdsize >= sizeof(struct build_version_command)) {
            const struct build_version_command *build = (const void *)cmd;
            television = build->platform == PLATFORM_TVOS;
            // Optional/weak-linked SDK stubs can deliberately advertise a future
            // OS (SceneBox ships such frameworks). Only the app's deployment
            // target is an install requirement; dyld handles libraries it uses.
            if (mainExecutable && build->minos > systemVersion)
                return TVExecutableError(@"This app needs a newer version of tvOS.");
        }
        if (cmd->cmd == LC_VERSION_MIN_TVOS) television = YES;
        if (cmd->cmd == LC_MAIN && cmd->cmdsize >= sizeof(struct entry_point_command)) {
            uint64_t offset = ((const struct entry_point_command *)cmd)->entryoff;
            entry = offset > 0 && offset < data.length;
        }
        if (cmd->cmd == LC_SEGMENT_64) {
            if (cmd->cmdsize < sizeof(struct segment_command_64)) return TVExecutableError(@"Truncated Mach-O segment.");
            const struct segment_command_64 *segment = (const void *)cmd;
            if (segment->nsects > (cmd->cmdsize - sizeof(*segment)) / sizeof(struct section_64)) return TVExecutableError(@"Invalid Mach-O sections.");
            const struct section_64 *sections = (const void *)(segment + 1);
            for (uint32_t j = 0; j < segment->nsects; j++) {
                if (!strncmp(sections[j].sectname, "__text", 16)) {
                    text = sections[j].offset >= end && sections[j].offset < data.length;
                }
            }
        }
        if ((cmd->cmd == LC_ENCRYPTION_INFO_64 || cmd->cmd == LC_ENCRYPTION_INFO) &&
            cmd->cmdsize >= sizeof(struct encryption_info_command) && ((const struct encryption_info_command *)cmd)->cryptid)
            return TVExecutableError(@"Encrypted App Store apps cannot be hosted. Use a decrypted tvOS IPA.");
        cursor += cmd->cmdsize;
    }
    if (!television) return TVExecutableError(@"This is not a tvOS device app. iOS and simulator apps need to be rebuilt for Apple TV; changing their platform does not supply missing frameworks.");
    if (mainExecutable && (!entry || !text || header->filetype != MH_EXECUTE)) return TVExecutableError(@"The app has no supported executable entry point.");
    if (data != original && ![data writeToURL:url options:NSDataWritingAtomic error:&sliceError]) return sliceError;
    return nil;
}

