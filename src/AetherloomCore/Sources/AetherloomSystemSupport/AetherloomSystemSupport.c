#include "AetherloomSystemSupport.h"

#include <errno.h>
#include <stdio.h>

#if defined(__APPLE__)
#include <copyfile.h>
#include <dlfcn.h>
#include <xattr_flags.h>
#endif

int
aetherloom_provenance_sync_intent(const char *name, int *result)
{
#if defined(__APPLE__)
    if (name == NULL || result == NULL) {
        return 2;
    }
    typedef int (*provenance_predicate_t)(const char *, int);
    provenance_predicate_t predicate = (provenance_predicate_t)dlsym(
        RTLD_DEFAULT,
        "xattr_preserve_for_intent"
    );
    if (predicate == NULL) {
        return 1;
    }
    *result = predicate(name, XATTR_OPERATION_INTENT_SYNC);
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
