#import "LCMachOUtils.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void checkPatch(int prefix, bool inject, bool payload) {
    NSMutableData *image = [NSMutableData dataWithLength:0x8000];
    struct mach_header_64 *header = image.mutableBytes;
    *header = (struct mach_header_64){.magic=MH_MAGIC_64, .cputype=CPU_TYPE_ARM64, .filetype=MH_EXECUTE, .flags=MH_PIE};
    uint8_t *cursor = (uint8_t *)(header + 1);
    struct segment_command_64 *zero = (void *)cursor;
    *zero = (struct segment_command_64){.cmd=LC_SEGMENT_64, .cmdsize=sizeof(*zero), .vmsize=0x100000000};
    strcpy(zero->segname, "__PAGEZERO"); cursor += sizeof(*zero);
    struct segment_command_64 *text = (void *)cursor;
    *text = (struct segment_command_64){.cmd=LC_SEGMENT_64, .cmdsize=sizeof(*text)+sizeof(struct section_64), .vmaddr=0x100000000, .vmsize=0x8000, .nsects=1};
    strcpy(text->segname, "__TEXT");
    struct section_64 *section = (void *)(text+1);
    strcpy(section->sectname, "__text"); section->offset=0x4000; section->addr=0x100004000; section->size=0x100;
    cursor += text->cmdsize;
    struct dylinker_command *linker = (void *)cursor;
    *linker = (struct dylinker_command){.cmd=LC_LOAD_DYLINKER, .cmdsize=32, .name.offset=12};
    strcpy((char *)cursor+12, "/usr/lib/dyld"); cursor += 32;
    struct entry_point_command *entry = (void *)cursor;
    *entry = (struct entry_point_command){.cmd=LC_MAIN, .cmdsize=sizeof(*entry), .entryoff=0x4000}; cursor += sizeof(*entry);
    struct linkedit_data_command *signature = (void *)cursor;
    *signature = (struct linkedit_data_command){.cmd=LC_CODE_SIGNATURE, .cmdsize=sizeof(*signature), .dataoff=0x7000}; cursor += sizeof(*signature);
    header->ncmds=5; header->sizeofcmds=(uint32_t)(cursor-(uint8_t *)(header+1));
    const char script[]="yttv\0\0\0\0(function(){window.fixture=true;})();";
    uint8_t *location = cursor + prefix;
    if (payload) memcpy(location, script, sizeof(script));
    const uint32_t originalSize = header->sizeofcmds;
    int result = LCPatchExecSlice("/fixture/YouTubeUnstable", header, inject);
    assert(header->filetype == MH_DYLIB);
    if (payload) assert(memcmp(location, script, sizeof(script)) == 0);
    bool identity = false, main = false;
    struct load_command *command = (void *)(header+1);
    for (uint32_t i=0; i<header->ncmds; i++) {
        assert(command->cmdsize >= sizeof(*command));
        if(command->cmd==LC_ID_DYLIB) identity=true;
        if(command->cmd==LC_MAIN) main=((struct entry_point_command *)command)->entryoff==0x4000;
        command=(void *)((char *)command+command->cmdsize);
    }
    assert(identity && main);
    if (payload && prefix < 40) {
        assert(header->sizeofcmds == originalSize);
        assert(result & PATCH_EXEC_RESULT_NO_SPACE_FOR_TWEAKLOADER);
    }
}
int main(void) {
    @autoreleasepool {
        for (int inject=0; inject<2; inject++) {
            checkPatch(0, inject, true);
            checkPatch(24, inject, true);
            checkPatch(128, inject, true);
            checkPatch(0, inject, false);
        }
        puts("Executable patch tests passed: embedded script payloads preserved, in-place ID fallback, entry points, empty padding, injection modes.");
    }
}
