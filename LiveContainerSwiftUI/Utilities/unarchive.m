#import "unarchive.h"

#include "archive.h"
#include "archive_entry.h"
#include <stdlib.h>
#include <limits.h>

static int
copy_data(struct archive *ar, struct archive *aw, NSProgress *progress)
{
  int r;
  const void *buff;
  size_t size;
  la_int64_t offset;

  for (;;) {
    r = archive_read_data_block(ar, &buff, &size, &offset);
    if (r == ARCHIVE_EOF)
      return (ARCHIVE_OK);
    if (r < ARCHIVE_OK)
      return (r);
    r = archive_write_data_block(aw, buff, size, offset);
    if (r < ARCHIVE_OK) {
      fprintf(stderr, "%s\n", archive_error_string(aw));
      return (r);
    }
    progress.completedUnitCount += size;
  }
}

int extract(NSString* fileToExtract, NSString* extractionPath, NSProgress* progress)
{
    struct archive *a;
    struct archive *ext;
    struct archive_entry *entry;
    int flags;
    int r;

    // NSString path normalization can turn /private/var back into /var on Apple
    // systems. Use the actual filesystem path for libarchive's symlink checks.
    char resolvedRoot[PATH_MAX];
    if (!realpath(extractionPath.fileSystemRepresentation, resolvedRoot)) return 1;
    NSString *root = @(resolvedRoot);

    /* Select which attributes we want to restore. */
    flags = ARCHIVE_EXTRACT_TIME;
    flags |= ARCHIVE_EXTRACT_PERM;
    flags |= ARCHIVE_EXTRACT_ACL;
    flags |= ARCHIVE_EXTRACT_FFLAGS;
    flags |= ARCHIVE_EXTRACT_SECURE_SYMLINKS;

    // Calculate decompressed size
    a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    if ((r = archive_read_open_filename(a, fileToExtract.fileSystemRepresentation, 10240))) {
        archive_read_free(a);
        return 1;
    }
    while ((r = archive_read_next_header(a, &entry)) != ARCHIVE_EOF) {
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(a));
        if (r < ARCHIVE_WARN) {
            archive_read_close(a);
            archive_read_free(a);
            return 1;
        }
        la_int64_t size = archive_entry_size(entry);
        // Bound expansion of downloaded archives and reject unexpected links.
        if (size < 0 || size > 8LL * 1024 * 1024 * 1024 - progress.totalUnitCount ||
            archive_entry_symlink(entry) || archive_entry_hardlink(entry)) {
            archive_read_free(a);
            return 1;
        }
        progress.totalUnitCount += size;
    }
    archive_read_close(a);
    archive_read_free(a);

    // Re-open the archive and extract
    a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    if ((r = archive_read_open_filename(a, fileToExtract.fileSystemRepresentation, 10240))) {
        archive_read_free(a);
        return 1;
    }
    ext = archive_write_disk_new();
    archive_write_disk_set_options(ext, flags);
    archive_write_disk_set_standard_lookup(ext);

    BOOL failed = NO;
    while ((r = archive_read_next_header(a, &entry)) != ARCHIVE_EOF) {
        if (r == ARCHIVE_EOF)
            break;
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(a));
        if (r < ARCHIVE_WARN) {
            failed = YES;
            break;
        }
        
        NSString* currentFile = [NSString stringWithUTF8String:archive_entry_pathname(entry)];
        NSString* fullOutputPath = [[root stringByAppendingString:@"/"] stringByAppendingString:currentFile];
        if (!currentFile.length || currentFile.isAbsolutePath || [currentFile.pathComponents containsObject:@".."] ||
            ![fullOutputPath hasPrefix:[root stringByAppendingString:@"/"]] ||
            archive_entry_symlink(entry) || archive_entry_hardlink(entry)) {
            failed = YES;
            break;
        }
        //printf("extracting %@ to %@\n", currentFile, fullOutputPath);
        archive_entry_set_pathname(entry, fullOutputPath.fileSystemRepresentation);
        
        r = archive_write_header(ext, entry);
        if (r < ARCHIVE_OK) {
            fprintf(stderr, "%s\n", archive_error_string(ext));
            failed = YES;
            break;
        }
        else if (archive_entry_size(entry) > 0) {
            r = copy_data(a, ext, progress);
            if (r < ARCHIVE_OK)
                fprintf(stderr, "%s\n", archive_error_string(ext));
            if (r < ARCHIVE_WARN) {
                failed = YES;
                break;
            }
        }
        r = archive_write_finish_entry(ext);
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(ext));
        if (r < ARCHIVE_WARN) {
            failed = YES;
            break;
        }
    }
    archive_read_close(a);
    archive_read_free(a);
    archive_write_close(ext);
    archive_write_free(ext);
    
    return failed || r != ARCHIVE_EOF ? 1 : 0;
}
