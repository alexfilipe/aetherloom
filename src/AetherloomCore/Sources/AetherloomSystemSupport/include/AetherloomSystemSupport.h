#ifndef AETHERLOOM_SYSTEM_SUPPORT_H
#define AETHERLOOM_SYSTEM_SUPPORT_H

// Returns 0 when the native predicate ran, 1 when it is unavailable, and 2
// when the wrapper could not invoke it. The native zero/nonzero result is
// written to result only when this function returns 0.
int aetherloom_provenance_sync_intent(const char *name, int *result);

// Copies only regular-file data. A nonzero recursive argument copies a
// directory tree without requesting metadata or extended attributes.
// Returns 0 on success or a positive errno value on failure.
int aetherloom_copy_data_fork(
    const char *source,
    const char *destination,
    int recursive
);

// Applies only the regular source file's modification time to the regular
// destination file without following symlinks. This is the one filesystem
// field represented by the synchronized ItemVersion; it does not copy xattrs
// or other metadata. Returns 0 on success or a positive errno value.
int aetherloom_apply_regular_file_modification_time(
    const char *source,
    const char *destination
);

// Atomically replaces destination with source through rename(2). This moves
// the new object and does not request metadata transfer from either object.
// Returns 0 on success or a positive errno value on failure.
int aetherloom_replace_item(const char *source, const char *destination);

#endif
