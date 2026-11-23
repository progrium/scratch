/* uitcore.h: the C ABI between the uitree core (Zig, libuitcore) and a
 * renderer (GPUI in Rust, the terminal in Zig).
 *
 * Version 5: version 4 plus uit_token_text, for the look tokens that
 * aren't colors (radius, radius-lg, font-size, font-family, spacing,
 * shadow).
 * Version 4: version 3 plus uit_themes: the renderer registers the named
 * themes it draws.
 * Version 3: version 2 plus the transfer layer's uit_drag: a platform drop
 * passes file=HOST-PATH and TYPE=BYTES attrs that the core turns into the
 * offer and file handles, START and END send dragstart and dragend.
 * Version 2: version 1 (frozen by the spike, W0) plus uit_asset. A change after the freeze bumps
 * UIT_ABI_VERSION and is announced to W3 (tree), W6 (GPUI) and W7 (TUI).
 * Adding a UIT_CMD_* tag, a UIT_ARG_* kind or a UitErr code is not a
 * change: a renderer ignores tags and kinds it doesn't know.
 *
 * The rules every function follows (../ARCHITECTURE.md, "Threads and
 * ownership"):
 *
 * 1. One owner thread. Every uit_* call except uit_abi_version,
 *    uit_wake_* and uit_shutdown comes from the thread that called
 *    uit_create. Debug builds of the core assert it.
 * 2. The core wakes, the renderer pumps. 9P threads queue ops and call
 *    UitConfig.wake from their own thread. The renderer then calls
 *    uit_pump on the owner thread, which applies every queued op in
 *    order, publishes the snapshot 9P readers use, acks the writers and
 *    returns what changed.
 * 3. Borrowed reads. Every UitStr, array and node handle the core returns
 *    is valid until the next uit_pump or uit_destroy. Inputs are copied
 *    before the call returns.
 * 4. No callbacks during a pump except wake. No re-entrancy.
 * 5. Errors are negative UitErr codes; uit_last_error gives the protocol's
 *    text (`bad value: read-only`). Panics abort on both sides; nothing
 *    unwinds across this boundary.
 *
 * Strings are UTF-8, not NUL-terminated, and may be empty ({NULL, 0}).
 * Paths are window-relative unless a function says otherwise, as in
 * protocols/core.md § Paths: `.` is a window's root, `f/ok` a node in it.
 * Style words and file names use the protocol's dashed spelling.
 */
#ifndef UITCORE_H
#define UITCORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define UIT_ABI_VERSION 5u

/* ---------------------------------------------------------------------
 * Basic types
 */

typedef struct UitCore UitCore;

/* A node handle. 0 is none. Stable for the node's life, never reused. */
typedef uint32_t UitNode;

/* A borrowed byte string. Not NUL-terminated. */
typedef struct {
    const uint8_t *ptr;
    size_t len;
} UitStr;

/* name=value. In inputs, both are copied. */
typedef struct {
    UitStr name;
    UitStr value;
} UitAttr;

typedef enum {
    UIT_OK = 0,
    UIT_EINVAL = -1,     /* bad argument from the renderer (null, bad handle) */
    UIT_ENOMEM = -2,
    UIT_ENOTFOUND = -3,  /* protocol `not found` */
    UIT_EINUSE = -4,     /* protocol `in use` */
    UIT_EBADVALUE = -5,  /* protocol `bad value`, `unknown style word`, ... */
    UIT_ETHREAD = -6,    /* called from a thread that isn't the owner */
    UIT_ENOTSUP = -7,    /* not implemented by this core build */
    UIT_EGONE = -8,      /* protocol `app gone`: the app quit */
    UIT_EVERSION = -9,   /* UitConfig.abi_version doesn't match the library */
    UIT_EIO = -10,       /* a socket, fd or machine failed */
    UIT_ETYPES = -11     /* the renderer registered a type the core lacks */
} UitErr;

/* The ABI version libuitcore was built with. A renderer checks it equals
 * UIT_ABI_VERSION at startup and refuses to run otherwise. Any thread. */
uint32_t uit_abi_version(void);

/* ---------------------------------------------------------------------
 * Lifecycle
 */

typedef struct {
    /* Must be UIT_ABI_VERSION; uit_create fails with UIT_EVERSION if not. */
    uint32_t abi_version;
    /* Descriptor text in components.md's grammar, every type the renderer
     * draws, concatenated (I6). Empty: the core's own built-in catalog. */
    UitStr types;
    /* `name argkind` per line, dashed (I7). Empty: accept any word. */
    UitStr style_words;
    /* `name light dark` per line, colors as #rrggbb[aa] (I7). */
    UitStr theme_tokens;
    /* The OS appearance at start: 0 light, 1 dark. */
    uint32_t system_dark;
    /* Called from any core thread when ops are queued: schedule uit_pump
     * on the owner thread. Must be cheap and must not call into the core. */
    void (*wake)(void *ctx);
    void *wake_ctx;
} UitConfig;

/* Makes a core. The calling thread becomes the owner thread. */
int uit_create(const UitConfig *cfg, UitCore **out);

/* Registers the named themes the renderer draws, replacing any before:
 * text in core/types/themes's format (a `theme NAME` line, then `mode
 * light|dark`, `family NAME` and `TOKEN #rrggbb[aa]` lines, each token one
 * the catalog has). $ui/theme/name then takes their names and family
 * names, and $ui/theme/names lists them; uit_token and theme/tokens resolve
 * through the selected palette. Call after uit_create and before serving
 * (UIT_EINUSE after uit_serve_fd, uit_listen or uit_run_machine).
 * UIT_EBADVALUE if the text doesn't parse. Since version 4. */
int uit_themes(UitCore *, UitStr text);

/* Serves $ui over 9P2000 on a connected fd (a socket or a pipe pair end)
 * until it closes. The core takes the fd. */
int uit_serve_fd(UitCore *, int fd);

/* Listens for 9P2000 connections on `addr` (`unix!PATH`, `tcp!HOST!PORT`).
 * Empty addr: a fresh unix socket in a private directory. The dial string
 * actually used is returned in *dial (borrowed until uit_destroy). */
int uit_listen(UitCore *, UitStr addr, UitStr *dial);

typedef struct {
    /* The program: a guest path (`rc`), or a host file (`./a.out`). */
    UitStr prog;
    /* argv including argv[0]. Empty: { prog }. */
    const UitStr *argv;
    size_t argc;
    /* --root: `builtin` (the default when empty) or a host directory. */
    UitStr root;
    /* The host directory the program starts in. Empty: the process cwd. */
    UitStr cwd;
    /* h9 --dir specs (`src:dst`). */
    const UitStr *dirs;
    size_t n_dirs;
    /* NAME=value lines for the guest, after `ui=/mnt/ui`. */
    const UitStr *env;
    size_t n_env;
    /* h9 sandbox flags as h9 spells them (`--net`, `--memory=1G`, ...). */
    const UitStr *h9_flags;
    size_t n_h9_flags;
    /* Host fds for the guest's stdout and stderr; -1 for the core's own. */
    int out_fd;
    int err_fd;
} UitMachineArgs;

/* Starts h9 on its own thread running args->prog with $ui mounted at
 * /mnt/ui and `ui` set in its environment. Returns at once. The exit is
 * reported by a pump (UitChanges.exited). One machine per core. */
int uit_run_machine(UitCore *, const UitMachineArgs *args);

/* Any thread. Hangs up: every events read ends, later 9P access fails
 * with `app gone`, and a running machine gets a hangup note. */
void uit_shutdown(UitCore *);

/* Frees the core. Stops serving and waits for the machine to end. */
void uit_destroy(UitCore *);

/* The protocol text of the last error on the owner thread. */
UitStr uit_last_error(UitCore *);

/* Any thread: as if the core's own 9P thread had queued an op. For a
 * renderer that wants a pump without one (tests). */
void uit_wake_renderer(UitCore *);

/* ---------------------------------------------------------------------
 * Pump
 */

typedef struct {
    UitNode node;
    UitStr file;  /* the prop file that changed: `text`, `style`, `order` */
} UitPropChange;

typedef enum {
    UIT_CMD_WINDOW = 1,        /* win: show (create if new) a window; read its props from its root */
    UIT_CMD_WINDOW_CTL = 2,    /* win, ctl: a window verb (show activate close destroy state notify ...) */
    UIT_CMD_QUIT = 3,          /* the app quits: close everything */
    UIT_CMD_MENUS = 4,         /* menus changed: re-read uit_menu_bar / uit_menu */
    UIT_CMD_KEYMAP = 5,        /* key bindings changed: re-read uit_keys */
    UIT_CMD_THEME = 6,         /* tokens or mode changed: re-read styles and uit_theme_dark */
    UIT_CMD_SET_ACTION = 7,    /* name = action id; flag = enabled (-1 unchanged, 0, 1); flag2 = check (-1, 0 off, 1 on, 2 mixed) */
    UIT_CMD_OVERLAY = 8,       /* win, node, name: overlay opens (flag 1) or closes (flag 0) */
    UIT_CMD_FOCUS = 9,         /* win, node: move key focus */
    UIT_CMD_CLIPBOARD = 10,    /* clipboard contents to publish (transfer layer) */
    UIT_CMD_COMPONENT_VERB = 11, /* node, ctl: a component verb (`scroll-to 3`, `select-all`) */
    UIT_CMD_ANSWER = 12,       /* seq, answer: the client answered request seq */
    UIT_CMD_REDRAW = 13,       /* win: a batch committed; redraw the window */
    UIT_CMD_THEME_LOAD = 14,   /* name = path: load a theme file in the renderer's format */
    UIT_CMD_ASSETS = 15        /* name: $ui/asset/NAME was written or removed; re-read it with uit_asset */
} UitHostCmdTag;

/* A pre-parsed ctl line, so the renderer never tokenizes. */
typedef struct {
    UitStr verb;
    const UitStr *args;   /* positional words after the verb */
    size_t n_args;
    const UitAttr *attrs; /* name=value words, in order */
    size_t n_attrs;
} UitCtl;

/* One host command. Which fields are set depends on tag (see above);
 * the rest are zero. */
typedef struct {
    uint32_t tag;   /* UitHostCmdTag; ignore one you don't know */
    UitStr win;
    UitNode node;
    UitStr name;
    UitCtl ctl;
    uint64_t seq;
    int32_t flag;
    int32_t flag2;
    UitStr answer;
} UitHostCmd;

typedef struct {
    const UitStr *dirty_windows; size_t n_dirty;  /* windows to redraw */
    const UitNode *created;  size_t n_created;
    const UitNode *removed;  size_t n_removed;    /* handles now dead */
    const UitPropChange *props; size_t n_props;
    const UitHostCmd *cmds;  size_t n_cmds;       /* in order */
    int32_t exited;          /* 1: the h9 client finished this pump */
    UitStr exit_status;      /* its exits string; empty is success */
} UitChanges;

/* Applies every queued op, publishes the 9P snapshot, acks writers and
 * fills *out (borrowed until the next pump). 0 or a UitErr. */
int uit_pump(UitCore *, UitChanges *out);

/* ---------------------------------------------------------------------
 * Reading the committed tree (borrowed until the next pump)
 */

/* The window names, in creation order. */
size_t  uit_windows(UitCore *, const UitStr **out);
/* A window's root node; 0 if there is no such window. */
UitNode uit_window_root(UitCore *, UitStr win);
/* Children in `order` order; a child not in `order` is left out. */
size_t  uit_children(UitCore *, UitNode, const UitNode **out);
/* A window's open overlays, bottom first. */
size_t  uit_overlays(UitCore *, UitStr win, const UitNode **out);
UitStr  uit_type(UitCore *, UitNode);
/* Window-relative path (`.`, `f/ok`, `over/x`). */
UitStr  uit_path(UitCore *, UitNode);
/* The node's window name. */
UitStr  uit_window_of(UitCore *, UitNode);
/* A prop file's value. 1 and *out set; 0 when unset; negative on error. */
int     uit_prop(UitCore *, UitNode, UitStr file, UitStr *out);

typedef enum {
    UIT_ARG_NONE = 0,
    UIT_ARG_PX = 1,       /* a: points */
    UIT_ARG_PERCENT = 2,  /* a: 0..100 */
    UIT_ARG_REM = 3,      /* a */
    UIT_ARG_NUMBER = 4,   /* a: unitless where the word says so (opacity, flex-grow) */
    UIT_ARG_RGBA = 5,     /* rgba: 0xRRGGBBAA, a theme token already resolved; text: the token name or empty */
    UIT_ARG_TEXT = 6      /* text: a word (font family, a size or variant name) */
} UitArgKind;

typedef struct {
    uint32_t kind;  /* UitArgKind */
    float a;
    uint32_t rgba;
    UitStr text;
} UitStyleArg;

typedef enum {
    UIT_STATE_BASE = 0,
    UIT_STATE_HOVER = 1,
    UIT_STATE_ACTIVE = 2,
    UIT_STATE_FOCUS = 3,
    UIT_STATE_DISABLED = 4,
    UIT_STATE_DROP_OVER = 5,
    UIT_STATE_GROUP_HOVER = 6   /* group: the group's name */
} UitStyleState;

typedef struct {
    UitStr name;     /* dashed: `items-center`, `bg` */
    uint32_t state;  /* UitStyleState */
    UitStr group;
    const UitStyleArg *args;  /* `name=a,b` gives two */
    size_t n_args;
} UitStyleWord;

/* The node's style, parsed, validated and with tokens resolved for the
 * current mode. Cached per node by the core. */
int uit_style(UitCore *, UitNode, const UitStyleWord **out, size_t *n);

typedef struct {
    const UitStr *fields;  /* tab-separated fields, or blank-separated words */
    size_t n_fields;
    uint32_t indent;       /* leading two-space steps (menus, trees) */
} UitLine;

typedef struct {
    const UitLine *lines;
    size_t n;
} UitLines;

/* A data file (`items`, `rows`, ...) split into lines and fields per its
 * format in the type's descriptor. */
int uit_lines(UitCore *, UitNode, UitStr file, UitLines *out);

typedef struct {
    UitStr keystroke;  /* `cmd-shift-p`; `cmd` is the host's command key */
    UitStr action;
    UitStr context;    /* empty: everywhere */
    uint32_t global;
} UitKeyBinding;

/* $ui/keys, parsed. */
int uit_keys(UitCore *, const UitKeyBinding **out, size_t *n);

typedef enum {
    UIT_MENU_ITEM = 0,
    UIT_MENU_SEP = 1,
    UIT_MENU_SUB = 2
} UitMenuKind;

typedef struct {
    uint32_t kind;     /* UitMenuKind */
    uint32_t depth;    /* nesting under a `sub` */
    UitStr id;         /* action id; `-` for none */
    UitStr label;
    UitStr key;
    UitStr icon;
    UitStr role;
    UitStr menu;       /* SUB: another menu file */
    int32_t enabled;   /* 1 or 0 */
    int32_t check;     /* -1 none, 0 off, 1 on, 2 mixed */
} UitMenuItem;

/* $ui/menu/bar's names, and one menu file's items. */
size_t uit_menu_bar(UitCore *, const UitStr **out);
int    uit_menu(UitCore *, UitStr name, const UitMenuItem **out, size_t *n);

/* $ui/asset/NAME's bytes (`src=@NAME`). 1 and *out set; 0 when there is
 * no such asset. Since version 2. */
int    uit_asset(UitCore *, UitStr name, UitStr *out);

/* The mode in effect: 0 light, 1 dark. */
uint32_t uit_theme_dark(UitCore *);
/* A token's color for the current mode, 0xRRGGBBAA. 1 found, 0 not. */
int      uit_token(UitCore *, UitStr name, uint32_t *rgba);
/* Any token's value for the current mode, as theme/tokens reads it: a
 * color as #rrggbb[aa], or a look token's value: radius, radius-lg,
 * font-size and spacing in points, font-family as text (`system` is the
 * host's UI font), shadow as on or off. 1 found, 0 not. Since version 5. */
int      uit_token_text(UitCore *, UitStr name, UitStr *out);

/* ---------------------------------------------------------------------
 * Input from the UI; queued and applied in order at the next pump
 */

/* An element or component event: `click`, `change`. attrs are the event's
 * own (value=go); the core adds win, path, key, via=user and seq. */
int      uit_emit(UitCore *, UitNode, UitStr name, const UitAttr *attrs, size_t n);
/* A request (`close`, `drop`): returns its seq, or 0 if the default answer
 * was applied at once. The answer arrives as UIT_CMD_ANSWER. */
uint64_t uit_request(UitCore *, UitNode, UitStr name, const UitAttr *attrs, size_t n, UitStr default_answer);
/* The user changed a prop the component owns (an input's value):
 * write it without a ctl op, via=user. */
int      uit_mirror(UitCore *, UitNode, UitStr file, UitStr value);
/* Layout result for the node's `bounds` file, window space. */
int      uit_bounds(UitCore *, UitNode, float x, float y, float w, float h);
/* A window's frame was drawn (ends a batch's wait, feeds /debug). */
int      uit_frame_drawn(UitCore *, UitStr win);
/* The user closed the window and the renderer already applied the answer. */
int      uit_window_closed(UitCore *, UitStr win);
/* A keystroke the renderer's own widgets didn't take. 1 if it matched a
 * binding (an `action` event follows), 0 if not. focused may be 0. */
int      uit_key(UitCore *, UitStr win, UitStr keystroke, UitNode focused);
/* A menu item was chosen: `action ID - via=menu`. */
int      uit_menu_action(UitCore *, UitStr id);
/* The OS appearance changed: 0 light, 1 dark. */
int      uit_system_dark(UitCore *, uint32_t dark);

typedef enum {
    UIT_DRAG_START = 0,
    UIT_DRAG_OVER = 1,
    UIT_DRAG_DROP = 2,
    UIT_DRAG_END = 3
} UitDragKind;

typedef struct {
    uint32_t kind;     /* UitDragKind */
    uint64_t drag;     /* the drag's number, from START's return */
    UitNode node;      /* the node under the pointer */
    float x, y;        /* window space */
    const UitAttr *attrs;
    size_t n_attrs;
} UitDragMsg;

/* Transfer layer (transfer.md).
 *
 * START: client node `node` (`on` has `drag`) starts a drag; the core
 *   makes drag/N offering its `drag-types`, sends `dragstart`, and returns
 *   N in *drag.
 * DROP: a drag is dropped on `node` at x,y. With drag 0 it comes from the
 *   platform and attrs are its offer: each `file=HOST-PATH` becomes a
 *   read-only file handle ($ui/file/ID) and an item of type `file`; any
 *   other `TYPE=BYTES` (text=, uri=, html=) one representation. The client
 *   sees bytes and handle names, never host paths. With drag N it is
 *   START's drag. The core sends the `drop` request (drag=N types=...
 *   pt=X,Y) and returns its seq in *drag (0 if the default applied). The
 *   answer comes as UIT_CMD_ANSWER: accept, or refuse (the default), which
 *   releases the handles the drop made.
 * END: START's drag ended, result=dropped|cancelled in attrs; the core
 *   sends `dragend` (with the target's op=) and drops drag/N.
 * OVER is the renderer's own business (the drop-over style). */
int uit_drag(UitCore *, const UitDragMsg *, uint64_t *drag);

#ifdef __cplusplus
}
#endif

#endif /* UITCORE_H */
