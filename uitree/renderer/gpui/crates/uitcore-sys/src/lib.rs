//! Raw bindings to `uitree/core/include/uitcore.h`, written by hand (no
//! bindgen). Keep in step with the header; `ABI_VERSION` and the layout
//! tests below catch drift. The rules (owner thread, borrowed reads, no
//! re-entrancy) are the header's; `uitcore` wraps them safely.
#![allow(non_camel_case_types, non_snake_case)]

use std::os::raw::{c_int, c_void};

pub const UIT_ABI_VERSION: u32 = 7;

#[repr(C)]
pub struct UitCore {
    _private: [u8; 0],
}

pub type UitNode = u32;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct UitStr {
    pub ptr: *const u8,
    pub len: usize,
}

impl UitStr {
    pub const EMPTY: UitStr = UitStr { ptr: std::ptr::null(), len: 0 };
    pub fn from_str(s: &str) -> UitStr {
        UitStr { ptr: s.as_ptr(), len: s.len() }
    }
    /// # Safety
    /// The string must still be valid (borrowed until the next pump).
    pub unsafe fn as_bytes<'a>(self) -> &'a [u8] {
        if self.ptr.is_null() || self.len == 0 { &[] } else { unsafe { std::slice::from_raw_parts(self.ptr, self.len) } }
    }
}

impl Default for UitStr {
    fn default() -> Self {
        UitStr::EMPTY
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct UitAttr {
    pub name: UitStr,
    pub value: UitStr,
}

pub const UIT_OK: c_int = 0;
pub const UIT_EINVAL: c_int = -1;
pub const UIT_ENOMEM: c_int = -2;
pub const UIT_ENOTFOUND: c_int = -3;
pub const UIT_EINUSE: c_int = -4;
pub const UIT_EBADVALUE: c_int = -5;
pub const UIT_ETHREAD: c_int = -6;
pub const UIT_ENOTSUP: c_int = -7;
pub const UIT_EGONE: c_int = -8;
pub const UIT_EVERSION: c_int = -9;
pub const UIT_EIO: c_int = -10;
pub const UIT_ETYPES: c_int = -11;

#[repr(C)]
pub struct UitConfig {
    pub abi_version: u32,
    pub types: UitStr,
    pub style_words: UitStr,
    pub theme_tokens: UitStr,
    pub system_dark: u32,
    pub wake: Option<unsafe extern "C" fn(ctx: *mut c_void)>,
    pub wake_ctx: *mut c_void,
}

#[repr(C)]
pub struct UitMachineArgs {
    pub prog: UitStr,
    pub argv: *const UitStr,
    pub argc: usize,
    pub root: UitStr,
    pub cwd: UitStr,
    pub dirs: *const UitStr,
    pub n_dirs: usize,
    pub env: *const UitStr,
    pub n_env: usize,
    pub h9_flags: *const UitStr,
    pub n_h9_flags: usize,
    pub out_fd: c_int,
    pub err_fd: c_int,
}

/// A connection the renderer carries itself (since 6). See uitcore.h.
#[repr(C)]
pub struct UitConn {
    pub read: Option<unsafe extern "C" fn(ctx: *mut c_void, buf: *mut u8, n: usize) -> isize>,
    pub write: Option<unsafe extern "C" fn(ctx: *mut c_void, buf: *const u8, n: usize) -> c_int>,
    pub hangup: Option<unsafe extern "C" fn(ctx: *mut c_void)>,
    pub release: Option<unsafe extern "C" fn(ctx: *mut c_void)>,
    pub ctx: *mut c_void,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct UitPropChange {
    pub node: UitNode,
    pub file: UitStr,
}

pub const UIT_CMD_WINDOW: u32 = 1;
pub const UIT_CMD_WINDOW_CTL: u32 = 2;
pub const UIT_CMD_QUIT: u32 = 3;
pub const UIT_CMD_MENUS: u32 = 4;
pub const UIT_CMD_KEYMAP: u32 = 5;
pub const UIT_CMD_THEME: u32 = 6;
pub const UIT_CMD_SET_ACTION: u32 = 7;
pub const UIT_CMD_OVERLAY: u32 = 8;
pub const UIT_CMD_FOCUS: u32 = 9;
pub const UIT_CMD_CLIPBOARD: u32 = 10;
pub const UIT_CMD_COMPONENT_VERB: u32 = 11;
pub const UIT_CMD_ANSWER: u32 = 12;
pub const UIT_CMD_REDRAW: u32 = 13;
pub const UIT_CMD_THEME_LOAD: u32 = 14;
pub const UIT_CMD_ASSETS: u32 = 15;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct UitCtl {
    pub verb: UitStr,
    pub args: *const UitStr,
    pub n_args: usize,
    pub attrs: *const UitAttr,
    pub n_attrs: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct UitHostCmd {
    pub tag: u32,
    pub win: UitStr,
    pub node: UitNode,
    pub name: UitStr,
    pub ctl: UitCtl,
    pub seq: u64,
    pub flag: i32,
    pub flag2: i32,
    pub answer: UitStr,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct UitChanges {
    pub dirty_windows: *const UitStr,
    pub n_dirty: usize,
    pub created: *const UitNode,
    pub n_created: usize,
    pub removed: *const UitNode,
    pub n_removed: usize,
    pub props: *const UitPropChange,
    pub n_props: usize,
    pub cmds: *const UitHostCmd,
    pub n_cmds: usize,
    pub exited: i32,
    pub exit_status: UitStr,
    /// ABI 7: files a renderer changed through `uit_mirror`.
    pub mirrors: *const UitPropChange,
    pub n_mirrors: usize,
}

impl Default for UitChanges {
    fn default() -> Self {
        // All pointers null, all counts zero.
        unsafe { std::mem::zeroed() }
    }
}

pub const UIT_ARG_NONE: u32 = 0;
pub const UIT_ARG_PX: u32 = 1;
pub const UIT_ARG_PERCENT: u32 = 2;
pub const UIT_ARG_REM: u32 = 3;
pub const UIT_ARG_NUMBER: u32 = 4;
pub const UIT_ARG_RGBA: u32 = 5;
pub const UIT_ARG_TEXT: u32 = 6;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct UitStyleArg {
    pub kind: u32,
    pub a: f32,
    pub rgba: u32,
    pub text: UitStr,
}

pub const UIT_STATE_BASE: u32 = 0;
pub const UIT_STATE_HOVER: u32 = 1;
pub const UIT_STATE_ACTIVE: u32 = 2;
pub const UIT_STATE_FOCUS: u32 = 3;
pub const UIT_STATE_DISABLED: u32 = 4;
pub const UIT_STATE_DROP_OVER: u32 = 5;
pub const UIT_STATE_GROUP_HOVER: u32 = 6;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct UitStyleWord {
    pub name: UitStr,
    pub state: u32,
    pub group: UitStr,
    pub args: *const UitStyleArg,
    pub n_args: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct UitLine {
    pub fields: *const UitStr,
    pub n_fields: usize,
    pub indent: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct UitLines {
    pub lines: *const UitLine,
    pub n: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct UitKeyBinding {
    pub keystroke: UitStr,
    pub action: UitStr,
    pub context: UitStr,
    pub global: u32,
}

pub const UIT_MENU_ITEM: u32 = 0;
pub const UIT_MENU_SEP: u32 = 1;
pub const UIT_MENU_SUB: u32 = 2;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct UitMenuItem {
    pub kind: u32,
    pub depth: u32,
    pub id: UitStr,
    pub label: UitStr,
    pub key: UitStr,
    pub icon: UitStr,
    pub role: UitStr,
    pub menu: UitStr,
    pub enabled: i32,
    pub check: i32,
}

pub const UIT_DRAG_START: u32 = 0;
pub const UIT_DRAG_OVER: u32 = 1;
pub const UIT_DRAG_DROP: u32 = 2;
pub const UIT_DRAG_END: u32 = 3;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct UitDragMsg {
    pub kind: u32,
    pub drag: u64,
    pub node: UitNode,
    pub x: f32,
    pub y: f32,
    pub attrs: *const UitAttr,
    pub n_attrs: usize,
}

// Linked from libuitcore.a on every target, the browser's included
// (build.rs; uitree/web/README.md).
unsafe extern "C" {
    pub fn uit_abi_version() -> u32;

    pub fn uit_create(cfg: *const UitConfig, out: *mut *mut UitCore) -> c_int;
    pub fn uit_serve_fd(c: *mut UitCore, fd: c_int) -> c_int;
    pub fn uit_serve_conn(c: *mut UitCore, conn: *const UitConn) -> c_int;
    pub fn uit_listen(c: *mut UitCore, addr: UitStr, dial: *mut UitStr) -> c_int;
    pub fn uit_run_machine(c: *mut UitCore, args: *const UitMachineArgs) -> c_int;
    pub fn uit_shutdown(c: *mut UitCore);
    pub fn uit_destroy(c: *mut UitCore);
    pub fn uit_last_error(c: *mut UitCore) -> UitStr;
    pub fn uit_wake_renderer(c: *mut UitCore);

    pub fn uit_pump(c: *mut UitCore, out: *mut UitChanges) -> c_int;

    pub fn uit_windows(c: *mut UitCore, out: *mut *const UitStr) -> usize;
    pub fn uit_window_root(c: *mut UitCore, win: UitStr) -> UitNode;
    pub fn uit_children(c: *mut UitCore, n: UitNode, out: *mut *const UitNode) -> usize;
    pub fn uit_overlays(c: *mut UitCore, win: UitStr, out: *mut *const UitNode) -> usize;
    pub fn uit_type(c: *mut UitCore, n: UitNode) -> UitStr;
    pub fn uit_path(c: *mut UitCore, n: UitNode) -> UitStr;
    pub fn uit_window_of(c: *mut UitCore, n: UitNode) -> UitStr;
    pub fn uit_prop(c: *mut UitCore, n: UitNode, file: UitStr, out: *mut UitStr) -> c_int;
    pub fn uit_style(c: *mut UitCore, n: UitNode, out: *mut *const UitStyleWord, len: *mut usize) -> c_int;
    pub fn uit_lines(c: *mut UitCore, n: UitNode, file: UitStr, out: *mut UitLines) -> c_int;
    pub fn uit_keys(c: *mut UitCore, out: *mut *const UitKeyBinding, n: *mut usize) -> c_int;
    pub fn uit_menu_bar(c: *mut UitCore, out: *mut *const UitStr) -> usize;
    pub fn uit_menu(c: *mut UitCore, name: UitStr, out: *mut *const UitMenuItem, n: *mut usize) -> c_int;
    pub fn uit_theme_dark(c: *mut UitCore) -> u32;
    pub fn uit_token(c: *mut UitCore, name: UitStr, rgba: *mut u32) -> c_int;
    pub fn uit_token_text(c: *mut UitCore, name: UitStr, out: *mut UitStr) -> c_int;
    pub fn uit_asset(c: *mut UitCore, name: UitStr, out: *mut UitStr) -> c_int;
    pub fn uit_themes(c: *mut UitCore, text: UitStr) -> c_int;

    pub fn uit_emit(c: *mut UitCore, n: UitNode, name: UitStr, attrs: *const UitAttr, len: usize) -> c_int;
    pub fn uit_request(c: *mut UitCore, n: UitNode, name: UitStr, attrs: *const UitAttr, len: usize, default_answer: UitStr) -> u64;
    pub fn uit_mirror(c: *mut UitCore, n: UitNode, file: UitStr, value: UitStr) -> c_int;
    pub fn uit_bounds(c: *mut UitCore, n: UitNode, x: f32, y: f32, w: f32, h: f32) -> c_int;
    pub fn uit_frame_drawn(c: *mut UitCore, win: UitStr) -> c_int;
    pub fn uit_window_closed(c: *mut UitCore, win: UitStr) -> c_int;
    pub fn uit_key(c: *mut UitCore, win: UitStr, keystroke: UitStr, focused: UitNode) -> c_int;
    pub fn uit_menu_action(c: *mut UitCore, id: UitStr) -> c_int;
    pub fn uit_system_dark(c: *mut UitCore, dark: u32) -> c_int;
    pub fn uit_drag(c: *mut UitCore, msg: *const UitDragMsg, drag: *mut u64) -> c_int;

    // The renderer tree (protocols/render.md). Since 7.
    pub fn uit_render_listen(c: *mut UitCore, addr: UitStr, flags: u32, dial: *mut UitStr) -> c_int;
    pub fn uit_render_serve_fd(c: *mut UitCore, fd: c_int, flags: u32) -> c_int;
    pub fn uit_render_serve_conn(c: *mut UitCore, conn: *const UitConn, flags: u32) -> c_int;
    pub fn uit_render_dial(c: *mut UitCore, addr: UitStr, name: UitStr, role: UitStr) -> c_int;
    pub fn uit_node_props(c: *mut UitCore, n: UitNode, out: *mut *const UitStr, len: *mut usize) -> c_int;
}

/// The host draws the app itself: 9P renderers can be mirrors or views.
pub const UIT_RENDER_HOST_DRAWS: u32 = 1;

/// In the browser the core is linked in with wasi-libc, whose malloc
/// takes the memory above the heap base as its own on first use, so it
/// must be the only allocator: Rust's goes through it too.
#[cfg(target_family = "wasm")]
mod web_alloc {
    use std::alloc::{GlobalAlloc, Layout};
    use std::os::raw::c_void;

    unsafe extern "C" {
        fn malloc(n: usize) -> *mut c_void;
        fn aligned_alloc(align: usize, n: usize) -> *mut c_void;
        fn calloc(k: usize, n: usize) -> *mut c_void;
        fn realloc(p: *mut c_void, n: usize) -> *mut c_void;
        fn free(p: *mut c_void);
    }

    /// malloc's own alignment on wasm32 (wasi-libc's dlmalloc).
    const MIN_ALIGN: usize = 16;

    struct Libc;

    unsafe impl GlobalAlloc for Libc {
        unsafe fn alloc(&self, l: Layout) -> *mut u8 {
            unsafe {
                if l.align() <= MIN_ALIGN { malloc(l.size()) as *mut u8 } else { aligned_alloc(l.align(), l.size().next_multiple_of(l.align())) as *mut u8 }
            }
        }
        unsafe fn alloc_zeroed(&self, l: Layout) -> *mut u8 {
            if l.align() <= MIN_ALIGN {
                return unsafe { calloc(1, l.size()) as *mut u8 };
            }
            let p = unsafe { self.alloc(l) };
            if !p.is_null() {
                unsafe { p.write_bytes(0, l.size()) };
            }
            p
        }
        unsafe fn dealloc(&self, p: *mut u8, _: Layout) {
            unsafe { free(p as *mut c_void) }
        }
        unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
            if l.align() <= MIN_ALIGN {
                return unsafe { realloc(p as *mut c_void, n) as *mut u8 };
            }
            let q = unsafe { self.alloc(Layout::from_size_align_unchecked(n, l.align())) };
            if !q.is_null() {
                unsafe {
                    std::ptr::copy_nonoverlapping(p, q, l.size().min(n));
                    self.dealloc(p, l);
                }
            }
            q
        }
    }

    #[global_allocator]
    static A: Libc = Libc;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{offset_of, size_of};

    #[test]
    fn library_matches_bindings() {
        assert_eq!(unsafe { uit_abi_version() }, UIT_ABI_VERSION);
    }

    // The layouts every 64-bit target gives the header's structs (C rules:
    // natural alignment, no packing). A change here is an ABI change.
    #[cfg(target_pointer_width = "64")]
    #[test]
    fn layouts() {
        assert_eq!(size_of::<UitStr>(), 16);
        assert_eq!(size_of::<UitAttr>(), 32);
        assert_eq!(size_of::<UitConfig>(), 80);
        assert_eq!(offset_of!(UitConfig, wake), 64);
        assert_eq!(size_of::<UitMachineArgs>(), 120);
        assert_eq!(size_of::<UitPropChange>(), 24);
        assert_eq!(size_of::<UitCtl>(), 48);
        assert_eq!(offset_of!(UitHostCmd, ctl), 48);
        assert_eq!(offset_of!(UitHostCmd, seq), 96);
        assert_eq!(size_of::<UitHostCmd>(), 128);
        assert_eq!(size_of::<UitChanges>(), 120);
        assert_eq!(size_of::<UitStyleArg>(), 32);
        assert_eq!(size_of::<UitStyleWord>(), 56);
        assert_eq!(size_of::<UitLine>(), 24);
        assert_eq!(size_of::<UitKeyBinding>(), 56);
        assert_eq!(size_of::<UitMenuItem>(), 112);
        assert_eq!(size_of::<UitDragMsg>(), 48);
        assert_eq!(size_of::<UitConn>(), 40);
    }
}
