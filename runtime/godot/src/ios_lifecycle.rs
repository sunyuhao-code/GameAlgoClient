//! UIKit notifications run independently of Godot's paused frame loop.
use crate::event_backend::EventBackend;
use std::ffi::{CStr, c_char};
use std::sync::Mutex;

static BACKEND: Mutex<Option<EventBackend>> = Mutex::new(None);

unsafe extern "C" {
    fn gamealgo_godot_lifecycle_install() -> i32;
    fn gamealgo_godot_lifecycle_uninstall();
}

pub(crate) fn register(backend: EventBackend) -> bool {
    let Ok(mut current) = BACKEND.lock() else {
        return false;
    };
    *current = Some(backend);
    drop(current);
    // The observer immediately reports the current application state, before
    // consent can start a session (including configuration while backgrounded).
    unsafe { gamealgo_godot_lifecycle_install() != 0 }
}

pub(crate) fn unregister() {
    unsafe { gamealgo_godot_lifecycle_uninstall() };
    if let Ok(mut current) = BACKEND.lock() {
        *current = None;
    }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn gamealgo_godot_lifecycle_update(
    foreground: i32,
    now_ms: i64,
    timestamp: *const c_char,
    created_local_at: *const c_char,
    next_event_id: *const c_char,
) -> i32 {
    if timestamp.is_null() || created_local_at.is_null() || next_event_id.is_null() {
        return 0;
    }
    let backend = BACKEND.lock().ok().and_then(|current| current.clone());
    let Some(backend) = backend else {
        return 0;
    };
    // All pointers are borrowed, NUL-terminated NSString UTF8Strings kept alive
    // by the synchronous Objective-C call. No Godot objects cross this boundary.
    let strings = unsafe {
        (
            CStr::from_ptr(timestamp).to_str(),
            CStr::from_ptr(created_local_at).to_str(),
            CStr::from_ptr(next_event_id).to_str(),
        )
    };
    let (Ok(timestamp), Ok(local), Ok(event_id)) = strings else {
        return 0;
    };
    i32::from(backend.lifecycle(foreground != 0, now_ms, timestamp, local, event_id))
}

#[unsafe(no_mangle)]
unsafe extern "C" fn gamealgo_godot_duration_sample(
    foreground: i32,
    now_ms: i64,
    timestamp: *const c_char,
    local: *const c_char,
) {
    if timestamp.is_null() || local.is_null() {
        return;
    }
    let (Ok(timestamp), Ok(local)) = (unsafe { CStr::from_ptr(timestamp).to_str() }, unsafe {
        CStr::from_ptr(local).to_str()
    }) else {
        return;
    };
    let backend = BACKEND.lock().ok().and_then(|slot| slot.clone());
    if let Some(backend) = backend {
        backend.sample_duration_at(foreground != 0, now_ms, timestamp, local);
    }
}
