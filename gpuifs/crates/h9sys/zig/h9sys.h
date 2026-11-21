/* gpuifs's C ABI over h9.Machine (DESIGN.md § Embedding h9), as shim.zig
 * exports it. String arrays are NULL-terminated. */
#include <stddef.h>

typedef struct H9Machine H9Machine;

typedef struct {
    const char *root;        /* "builtin", or an absolute host path to a 9front tree */
    const char *cwd;         /* absolute host path, bound at /mnt/term/cwd */
    const char *const *dirs; /* extra --dir mounts, "SRC:DST[:OPTS]" */
    int ninep_fd;            /* the guest end of the socket pair, or -1 */
    const char *ninep_dst;   /* "/mnt/gpui"; "" mounts nothing */
    const char *const *env;  /* "name=value", with gpuifs=/mnt/gpui */
    int out_fd, err_fd;      /* the client's stdout and stderr */
    const char *profile;     /* h9 policy profile, plus the flags below */
    const char *const *policy_flags; /* --net, --write, --timeout, ... as h9 parses them */
} H9Config;

int  h9_new(const H9Config *cfg, H9Machine **m, char *err, size_t errlen);
int  h9_run(H9Machine *m, const char *prog, const char *const *argv,
            char *status, size_t statuslen);  /* blocks until the client exits */
void h9_hangup(H9Machine *m);                 /* any thread */
void h9_stop(H9Machine *m);                   /* any thread */
void h9_free(H9Machine *m);
