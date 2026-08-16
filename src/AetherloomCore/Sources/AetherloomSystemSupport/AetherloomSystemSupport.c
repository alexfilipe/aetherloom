#include "AetherloomSystemSupport.h"

#include <errno.h>
#include <stdio.h>

#if defined(__APPLE__)
#include <copyfile.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <xattr_flags.h>
#endif

int
aetherloom_provenance_sync_intent(const char *name, int *result)
{
#if defined(__APPLE__)
    if (name == NULL || result == NULL) {
        return 2;
    }
    *result = xattr_preserve_for_intent(name, XATTR_OPERATION_INTENT_SYNC);
    return 0;
#else
    (void)name;
    (void)result;
    return 1;
#endif
}

int
aetherloom_copy_data_fork(
    const char *source,
    const char *destination,
    int recursive
)
{
#if defined(__APPLE__)
    if (source == NULL || destination == NULL) {
        return EINVAL;
    }
    copyfile_flags_t flags = COPYFILE_DATA | COPYFILE_NOFOLLOW_SRC;
    if (recursive != 0) {
        flags |= COPYFILE_RECURSIVE;
    }
    if (copyfile(source, destination, NULL, flags) == 0) {
        return 0;
    }
    return errno == 0 ? EIO : errno;
#else
    (void)source;
    (void)destination;
    (void)recursive;
    return ENOTSUP;
#endif
}

int
aetherloom_apply_regular_file_modification_time(
    const char *source,
    const char *destination
)
{
#if defined(__APPLE__)
    if (source == NULL || destination == NULL) {
        return EINVAL;
    }
    struct stat source_status;
    struct stat destination_status;
    if (lstat(source, &source_status) != 0) {
        return errno == 0 ? EIO : errno;
    }
    if (lstat(destination, &destination_status) != 0) {
        return errno == 0 ? EIO : errno;
    }
    if (!S_ISREG(source_status.st_mode)
        || !S_ISREG(destination_status.st_mode)) {
        return EINVAL;
    }
    struct timespec times[2] = {
        { .tv_sec = 0, .tv_nsec = UTIME_OMIT },
        source_status.st_mtimespec,
    };
    if (utimensat(
        AT_FDCWD,
        destination,
        times,
        AT_SYMLINK_NOFOLLOW
    ) == 0) {
        return 0;
    }
    return errno == 0 ? EIO : errno;
#else
    (void)source;
    (void)destination;
    return ENOTSUP;
#endif
}

int
aetherloom_replace_item(const char *source, const char *destination)
{
    if (source == NULL || destination == NULL) {
        return EINVAL;
    }
    if (rename(source, destination) == 0) {
        return 0;
    }
    return errno == 0 ? EIO : errno;
}
