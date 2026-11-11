#import "TVMachOSlice.h"
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <libkern/OSByteOrder.h>

BOOL TVIsMachO(NSData *data) {
    if (data.length < 4) return NO;
    uint32_t magic; memcpy(&magic, data.bytes, 4);
    return magic == MH_MAGIC_64 || magic == MH_CIGAM_64 || magic == MH_MAGIC || magic == MH_CIGAM ||
        magic == FAT_MAGIC || magic == FAT_CIGAM || magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64;
}

NSData *TVArm64Slice(NSData *data, NSError **error) {
    NSString *message = @"The binary has no compatible arm64 device slice.";
    uint32_t magic = 0;
    if (data.length >= 4) memcpy(&magic, data.bytes, 4);
    if (magic == MH_MAGIC_64) return data; // Platform and CPU validated by caller.
    BOOL wide = magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64;
    BOOL fat = wide || magic == FAT_MAGIC || magic == FAT_CIGAM;
    if (fat && data.length >= sizeof(struct fat_header)) {
        BOOL swap = magic == FAT_CIGAM || magic == FAT_CIGAM_64;
        uint32_t (^u32)(uint32_t) = ^uint32_t(uint32_t v) { return swap ? OSSwapInt32(v) : v; };
        uint64_t (^u64)(uint64_t) = ^uint64_t(uint64_t v) { return swap ? OSSwapInt64(v) : v; };
        struct fat_header header; memcpy(&header, data.bytes, sizeof(header));
        size_t size = wide ? sizeof(struct fat_arch_64) : sizeof(struct fat_arch);
        uint32_t count = u32(header.nfat_arch);
        message = @"The universal binary has an invalid architecture table.";
        if (count && count <= (data.length - sizeof(header)) / size) {
            uint64_t tableEnd = sizeof(header) + count * size;
            NSRange selected = NSMakeRange(NSNotFound, 0);
            for (uint32_t i = 0; i < count; i++) {
                uint64_t offset, length; uint32_t cpu, subtype, alignment;
                const void *record = (const uint8_t *)data.bytes + sizeof(header) + i * size;
                if (wide) {
                    struct fat_arch_64 arch; memcpy(&arch, record, sizeof(arch));
                    offset = u64(arch.offset); length = u64(arch.size);
                    cpu = u32(arch.cputype); subtype = u32(arch.cpusubtype); alignment = u32(arch.align);
                } else {
                    struct fat_arch arch; memcpy(&arch, record, sizeof(arch));
                    offset = u32(arch.offset); length = u32(arch.size);
                    cpu = u32(arch.cputype); subtype = u32(arch.cpusubtype); alignment = u32(arch.align);
                }
                if (offset < tableEnd || offset > data.length || length > data.length - offset ||
                    length < sizeof(struct mach_header_64) || alignment > 62 || offset % (1ULL << alignment)) goto failed;
                if (cpu == CPU_TYPE_ARM64 && (subtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64_ALL)
                    selected = NSMakeRange((NSUInteger)offset, (NSUInteger)length);
            }
            message = @"The universal binary has no compatible arm64 device slice.";
            if (selected.location != NSNotFound) {
                NSData *slice = [data subdataWithRange:selected];
                struct mach_header_64 inner; memcpy(&inner, slice.bytes, sizeof(inner));
                if (inner.magic == MH_MAGIC_64 && inner.cputype == CPU_TYPE_ARM64 &&
                    (inner.cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64_ALL) return slice;
                message = @"The universal binary's arm64 header does not match its architecture table.";
            }
        }
    }
failed:
    if (error) *error = [NSError errorWithDomain:@"TVContainer" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
    return nil;
}
