//! `click-through=on|off` (shell.md § Window props): the whole window
//! ignores the pointer, so clicks and scrolls reach what is behind it.
//!
//! GPUI has no portable call for this, so each platform gets its own:
//!
//! - macOS: `-[NSWindow setIgnoresMouseEvents:]` on the view's window.
//! - Windows: `WS_EX_LAYERED | WS_EX_TRANSPARENT` on the HWND (with an
//!   opaque layered alpha, so the window still draws).
//! - Linux, Wayland: an empty input region (`Window::set_input_region`).
//! - Linux, X11: an empty XShape input region on the window.
//! - The web: nothing (the page is the window).
//!
//! It is whole-window: a transparent window with click-through is a
//! display-only overlay. Keyboard focus is unchanged; a client that wants
//! input again sets `click-through=off`.

use gpui::Window;

/// Turns click-through on or off for an open window.
pub(crate) fn set(window: &mut Window, on: bool) {
    #[cfg(not(target_family = "wasm"))]
    {
        use raw_window_handle::{HasWindowHandle as _, RawWindowHandle};
        // Wayland: GPUI's own call (a no-op on every other platform).
        #[cfg(any(target_os = "linux", target_os = "freebsd"))]
        {
            let none: &[gpui::Bounds<gpui::Pixels>] = &[];
            window.set_input_region(on.then_some(none));
        }
        let Ok(handle) = window.window_handle() else { return };
        match handle.as_raw() {
            #[cfg(target_os = "macos")]
            RawWindowHandle::AppKit(h) => macos(h.ns_view.as_ptr(), on),
            #[cfg(target_os = "windows")]
            RawWindowHandle::Win32(h) => win32(h.hwnd.get(), on),
            #[cfg(any(target_os = "linux", target_os = "freebsd"))]
            RawWindowHandle::Xcb(h) => {
                use raw_window_handle::{HasDisplayHandle as _, RawDisplayHandle};
                if let Ok(d) = window.display_handle()
                    && let RawDisplayHandle::Xcb(d) = d.as_raw()
                    && let Some(conn) = d.connection
                {
                    x11(conn.as_ptr(), h.window.get(), on);
                }
            }
            _ => {}
        }
    }
    #[cfg(target_family = "wasm")]
    let _ = (window, on);
}

#[cfg(target_os = "macos")]
fn macos(view: *mut std::ffi::c_void, on: bool) {
    use objc2::msg_send;
    use objc2::runtime::{AnyObject, Bool};
    // SAFETY: GPUI's AppKit handle is its live NSView, on the main thread.
    unsafe {
        let view = view.cast::<AnyObject>();
        let win: *mut AnyObject = msg_send![view, window];
        if !win.is_null() {
            let _: () = msg_send![win, setIgnoresMouseEvents: Bool::new(on)];
        }
    }
}

#[cfg(target_os = "windows")]
fn win32(hwnd: isize, on: bool) {
    use windows::Win32::Foundation::{COLORREF, HWND};
    use windows::Win32::UI::WindowsAndMessaging::{
        GWL_EXSTYLE, GetWindowLongPtrW, LWA_ALPHA, SetLayeredWindowAttributes, SetWindowLongPtrW, WS_EX_LAYERED,
        WS_EX_TRANSPARENT,
    };
    let hwnd = HWND(hwnd as *mut _);
    let bits = (WS_EX_LAYERED.0 | WS_EX_TRANSPARENT.0) as isize;
    // SAFETY: GPUI's Win32 handle is its live HWND, on the main thread.
    unsafe {
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let ex = if on { ex | bits } else { ex & !bits };
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex);
        if on {
            // A layered window draws nothing until it is given an alpha.
            let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 255, LWA_ALPHA);
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "freebsd"))]
fn x11(conn: *mut std::ffi::c_void, window: u32, on: bool) {
    use x11rb::connection::Connection as _;
    use x11rb::protocol::shape::{ConnectionExt as _, SK, SO};
    use x11rb::protocol::xproto::ClipOrdering;
    use x11rb::xcb_ffi::XCBConnection;
    // SAFETY: GPUI's own xcb connection, borrowed: `false` leaves it open.
    let Ok(c) = (unsafe { XCBConnection::from_raw_xcb_connection(conn, false) }) else { return };
    let r = if on {
        // An empty input region: every pointer event goes to the window below.
        c.shape_rectangles(SO::SET, SK::INPUT, ClipOrdering::UNSORTED, window, 0, 0, &[]).map(|_| ())
    } else {
        // No mask: the input region is the whole window again.
        c.shape_mask(SO::SET, SK::INPUT, window, 0, 0, x11rb::NONE).map(|_| ())
    };
    if r.is_ok() {
        let _ = c.flush();
    }
}
