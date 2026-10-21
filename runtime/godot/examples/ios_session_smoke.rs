//! Simulator-only fixture that links the production queue and UIKit observer,
//! without loading Godot. No test exports are added to the shipped framework.
#[cfg(target_os = "ios")]
#[path = "../src/event_backend.rs"]
mod event_backend;
#[cfg(target_os = "ios")]
#[path = "../src/ios_lifecycle.rs"]
mod ios_lifecycle;

#[cfg(target_os = "ios")]
#[unsafe(no_mangle)]
unsafe extern "C" fn gamealgo_smoke_start(path: *const std::ffi::c_char, now_ms: i64) -> i32 {
    use event_backend::EventBackend;
    use serde_json::json;
    use std::ffi::CStr;
    let path = unsafe { CStr::from_ptr(path) }.to_str().unwrap();
    let backend = EventBackend::new();
    if !backend.configure(
        path,
        "https://gamealgo.invalid/v1/events/batch",
        "ga_live_smoke",
        100,
        1000,
        "ios",
    ) || !ios_lifecycle::register(backend.clone())
    {
        return 0;
    }
    let id = format!("smoke-{}-{now_ms}", std::process::id());
    let event = json!({
        "eventId": format!("end-{id}"), "sessionId": id,
        "userId": "smoke-user", "contextId": "smoke-context",
        "eventType": "session_end", "isDebug": true,
        "timestamp": "2026-10-21T00:00:00.000Z",
        "createdLocalAt": "2026-10-21T08:00:00.000+08:00", "payload": {}
    });
    i32::from(backend.start_session(&event.to_string(), now_ms))
}
