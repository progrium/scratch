//! The native half of the window platform props: what GPUI doesn't expose,
//! done on the OS window behind a raw window handle. It depends on nothing
//! but `raw-window-handle` and the OS bindings, so it can be checked for
//! every target without building GPUI.
//!
//! - `top`: `off` is a normal window; `on` is above every normal and
//!   floating window but below the menu bar; `overlay` is above the menu
//!   bar and the dock, as Topframe's overlay is.
//! - `all-spaces`: on every Space (macOS) or virtual desktop.
//! - `shadow`: the window's drop shadow.
//! - `fill`: the window's frame becomes its display's (`display`) or the
//!   display's work area (`work`, without the menu bar and dock).
//! - `hidden`: ordered out without closing, and back.
//!
//! Each returns false where the platform has no such thing, and the caller
//! carries on: a prop a platform can't honor is ignored, not an error.


#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Top {
    Off,
    On,
    Overlay,
}

impl Top {
    pub fn parse(v: &str) -> Top {
        match v {
            "on" => Top::On,
            "overlay" => Top::Overlay,
            _ => Top::Off,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fill {
    None,
    Display,
    Work,
}

impl Fill {
    pub fn parse(v: &str) -> Fill {
        match v {
            "display" => Fill::Display,
            "work" => Fill::Work,
            _ => Fill::None,
        }
    }
}

#[cfg(target_os = "macos")]
pub use mac::*;

#[cfg(target_os = "windows")]
pub use win::*;

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
pub use other::*;

#[cfg(target_os = "macos")]
mod mac {
    use super::{Fill, Top};
    use objc2::encode::{Encode, Encoding};
    use objc2::msg_send;
    use objc2::runtime::{AnyObject, Bool};
    use raw_window_handle::RawWindowHandle;

    // NSWindowLevel values (CGWindowLevel.h).
    const NORMAL_LEVEL: isize = 0;
    const MAIN_MENU_LEVEL: isize = 24;
    // NSWindowCollectionBehavior bits.
    const CAN_JOIN_ALL_SPACES: usize = 1 << 0;
    const MOVE_TO_ACTIVE_SPACE: usize = 1 << 1;
    const STATIONARY: usize = 1 << 4;
    const FULL_SCREEN_AUXILIARY: usize = 1 << 8;

    #[repr(C)]
    #[derive(Clone, Copy, Debug)]
    struct Point {
        x: f64,
        y: f64,
    }
    #[repr(C)]
    #[derive(Clone, Copy, Debug)]
    struct Size {
        width: f64,
        height: f64,
    }
    #[repr(C)]
    #[derive(Clone, Copy, Debug)]
    struct Rect {
        origin: Point,
        size: Size,
    }
    unsafe impl Encode for Point {
        const ENCODING: Encoding = Encoding::Struct("CGPoint", &[f64::ENCODING, f64::ENCODING]);
    }
    unsafe impl Encode for Size {
        const ENCODING: Encoding = Encoding::Struct("CGSize", &[f64::ENCODING, f64::ENCODING]);
    }
    unsafe impl Encode for Rect {
        const ENCODING: Encoding = Encoding::Struct("CGRect", &[Point::ENCODING, Size::ENCODING]);
    }

    /// The NSWindow behind a GPUI window's NSView.
    fn ns_window(h: RawWindowHandle) -> Option<*mut AnyObject> {
        let RawWindowHandle::AppKit(a) = h else { return None };
        let view = a.ns_view.as_ptr().cast::<AnyObject>();
        // SAFETY: GPUI's view is a live NSView on the main thread.
        let w: *mut AnyObject = unsafe { msg_send![view, window] };
        (!w.is_null()).then_some(w)
    }

    pub fn set_top(h: RawWindowHandle, top: Top) -> bool {
        let Some(w) = ns_window(h) else { return false };
        let level = match top {
            Top::Off => NORMAL_LEVEL,
            Top::On => MAIN_MENU_LEVEL - 1,
            Top::Overlay => MAIN_MENU_LEVEL + 2,
        };
        unsafe {
            let _: () = msg_send![w, setLevel: level];
            if top == Top::Overlay {
                // Above a full-screen app's Space too.
                let b: usize = msg_send![w, collectionBehavior];
                let _: () = msg_send![w, setCollectionBehavior: b | FULL_SCREEN_AUXILIARY];
            }
        }
        true
    }

    pub fn set_all_spaces(h: RawWindowHandle, on: bool) -> bool {
        let Some(w) = ns_window(h) else { return false };
        unsafe {
            let b: usize = msg_send![w, collectionBehavior];
            let b = if on {
                (b & !MOVE_TO_ACTIVE_SPACE) | CAN_JOIN_ALL_SPACES | STATIONARY
            } else {
                b & !(CAN_JOIN_ALL_SPACES | STATIONARY)
            };
            let _: () = msg_send![w, setCollectionBehavior: b];
        }
        true
    }

    pub fn set_shadow(h: RawWindowHandle, on: bool) -> bool {
        let Some(w) = ns_window(h) else { return false };
        unsafe {
            let _: () = msg_send![w, setHasShadow: Bool::new(on)];
        }
        true
    }

    pub fn set_fill(h: RawWindowHandle, fill: Fill) -> bool {
        if fill == Fill::None {
            return true;
        }
        let Some(w) = ns_window(h) else { return false };
        unsafe {
            let mut screen: *mut AnyObject = msg_send![w, screen];
            if screen.is_null() {
                screen = msg_send![objc2::class!(NSScreen), mainScreen];
            }
            if screen.is_null() {
                return false;
            }
            let r: Rect = if fill == Fill::Work { msg_send![screen, visibleFrame] } else { msg_send![screen, frame] };
            let _: () = msg_send![w, setFrame: r, display: Bool::YES];
        }
        true
    }

    pub fn set_hidden(h: RawWindowHandle, hidden: bool) -> bool {
        let Some(w) = ns_window(h) else { return false };
        unsafe {
            if hidden {
                let _: () = msg_send![w, orderOut: std::ptr::null_mut::<AnyObject>()];
            } else {
                let _: () = msg_send![w, orderFront: std::ptr::null_mut::<AnyObject>()];
            }
        }
        true
    }

    /// `accessory`: no dock icon or app switcher entry (activation policy
    /// accessory), or back to a regular app.
    pub fn set_accessory(on: bool) -> bool {
        unsafe {
            let app: *mut AnyObject = msg_send![objc2::class!(NSApplication), sharedApplication];
            if app.is_null() {
                return false;
            }
            let policy: isize = if on { 1 } else { 0 };
            let _: Bool = msg_send![app, setActivationPolicy: policy];
        }
        true
    }
}

#[cfg(target_os = "windows")]
mod win {
    use super::{Fill, Top};
    use raw_window_handle::RawWindowHandle;
    use windows_sys::Win32::Foundation::{HWND, RECT};
    use windows_sys::Win32::Graphics::Gdi::{GetMonitorInfoW, MONITOR_DEFAULTTONEAREST, MONITORINFO, MonitorFromWindow};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        HWND_NOTOPMOST, HWND_TOPMOST, SW_HIDE, SW_SHOWNOACTIVATE, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER, SetWindowPos, ShowWindow,
    };

    fn hwnd(h: RawWindowHandle) -> Option<HWND> {
        let RawWindowHandle::Win32(w) = h else { return None };
        Some(w.hwnd.get() as HWND)
    }

    pub fn set_top(h: RawWindowHandle, top: Top) -> bool {
        let Some(w) = hwnd(h) else { return false };
        let after = if top == Top::Off { HWND_NOTOPMOST } else { HWND_TOPMOST };
        unsafe { SetWindowPos(w, after, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE) != 0 }
    }

    pub fn set_all_spaces(_h: RawWindowHandle, _on: bool) -> bool {
        false
    }

    pub fn set_shadow(_h: RawWindowHandle, _on: bool) -> bool {
        false
    }

    pub fn set_fill(h: RawWindowHandle, fill: Fill) -> bool {
        if fill == Fill::None {
            return true;
        }
        let Some(w) = hwnd(h) else { return false };
        unsafe {
            let mon = MonitorFromWindow(w, MONITOR_DEFAULTTONEAREST);
            let mut mi: MONITORINFO = std::mem::zeroed();
            mi.cbSize = std::mem::size_of::<MONITORINFO>() as u32;
            if GetMonitorInfoW(mon, &mut mi) == 0 {
                return false;
            }
            let r: RECT = if fill == Fill::Work { mi.rcWork } else { mi.rcMonitor };
            SetWindowPos(w, std::ptr::null_mut(), r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE) != 0
        }
    }

    pub fn set_hidden(h: RawWindowHandle, hidden: bool) -> bool {
        let Some(w) = hwnd(h) else { return false };
        unsafe {
            ShowWindow(w, if hidden { SW_HIDE } else { SW_SHOWNOACTIVATE });
        }
        true
    }

    pub fn set_accessory(_on: bool) -> bool {
        false
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
mod other {
    use super::{Fill, Top};
    use raw_window_handle::RawWindowHandle;

    pub fn set_top(_h: RawWindowHandle, _top: Top) -> bool {
        false
    }
    pub fn set_all_spaces(_h: RawWindowHandle, _on: bool) -> bool {
        false
    }
    pub fn set_shadow(_h: RawWindowHandle, _on: bool) -> bool {
        false
    }
    pub fn set_fill(_h: RawWindowHandle, _fill: Fill) -> bool {
        false
    }
    pub fn set_hidden(_h: RawWindowHandle, _hidden: bool) -> bool {
        false
    }
    pub fn set_accessory(_on: bool) -> bool {
        false
    }
}
