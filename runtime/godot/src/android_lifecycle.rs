//! JNI callbacks own no Godot values and can run while its render loop is stopped.
use crate::event_backend::EventBackend;
use jni::{
    JNIEnv,
    objects::{JClass, JString},
    sys::{jboolean, jlong},
};
use std::sync::Mutex;

static BACKEND: Mutex<Option<EventBackend>> = Mutex::new(None);

pub(crate) fn register(backend: EventBackend) {
    if let Ok(mut slot) = BACKEND.lock() {
        *slot = Some(backend);
    }
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_gamealgo_godot_GameAlgoLifecycle_nativeUpdate(
    mut env: JNIEnv,
    _class: JClass,
    foreground: jboolean,
    now_ms: jlong,
    timestamp: JString,
    created_local_at: JString,
    next_event_id: JString,
) -> jboolean {
    let backend = BACKEND.lock().ok().and_then(|slot| slot.clone());
    let Some(backend) = backend else {
        return 0;
    };
    let Ok(timestamp) = env.get_string(&timestamp).map(String::from) else {
        return 0;
    };
    let Ok(local) = env.get_string(&created_local_at).map(String::from) else {
        return 0;
    };
    let Ok(event_id) = env.get_string(&next_event_id).map(String::from) else {
        return 0;
    };
    backend.lifecycle(foreground != 0, now_ms, &timestamp, &local, &event_id) as jboolean
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_gamealgo_godot_GameAlgoLifecycle_nativeSample(
    mut env: JNIEnv,
    _class: JClass,
    foreground: jboolean,
    now_ms: jlong,
    timestamp: JString,
    local: JString,
) {
    let (Ok(timestamp), Ok(local)) = (
        env.get_string(&timestamp).map(String::from),
        env.get_string(&local).map(String::from),
    ) else {
        return;
    };
    let backend = BACKEND.lock().ok().and_then(|slot| slot.clone());
    if let Some(backend) = backend {
        backend.sample_duration_at(foreground != 0, now_ms, &timestamp, &local);
    }
}
