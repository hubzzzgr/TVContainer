"""Compile the production patcher without the unrelated dyld/runtime machinery."""
from pathlib import Path

source = Path('LiveContainer/LCMachOUtils.m').read_text()
parts = []
for start, end in [
    ('static uint32_t rnd32(', 'struct dyld_all_image_infos *_alt_'),
    ('static uint32_t get_chained_fixups_seg_count(', 'static void insertRPathCommand('),
    ('int LCPatchExecSlice(', 'NSString *LCParseMachO('),
]:
    parts.append(source[source.index(start):source.index(end)])
Path('build/exec_patcher.m').write_text('''
#import "LCMachOUtils.h"
#include <mach-o/fixup-chains.h>
#include <libgen.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
''' + '\n'.join(parts))
