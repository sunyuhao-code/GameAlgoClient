//! Godot binding for the canonical GameAlgo script runtime.
//!
//! This is a thin adapter: every sandbox budget, the prelude, and the execution
//! semantics live in `gamealgo-script-runtime`, which also backs iOS, Android
//! and the server. Nothing here re-implements them.
//!
//! The singleton exposes the interface `addons/gamealgo/gamealgo_script_runtime.gd`
//! expects: `is_available`, `prepare`, `has_prepared` and `execute_json`.

use gamealgo_script_runtime::{PreparedScript, RuntimeLimits};
use godot::classes::Engine;
use godot::prelude::*;
use serde_json::Value;
use std::collections::HashMap;

#[cfg(target_os = "android")]
mod android_lifecycle;
mod event_backend;

use event_backend::EventBackend;

/// Keeping a few prepared contexts alive covers the handful of strategies one
/// game runs. Beyond that the least recently used one is dropped.
const MAX_PREPARED_SCRIPTS: usize = 4;

const SINGLETON_NAME: &str = "GameAlgoRuntime";

struct GameAlgoRuntimeExtension;

#[gdextension]
unsafe impl ExtensionLibrary for GameAlgoRuntimeExtension {
    fn on_stage_init(stage: InitStage) {
        if stage != InitStage::Scene {
            return;
        }
        Engine::singleton().register_singleton(SINGLETON_NAME, &GameAlgoRuntime::new_alloc());
    }

    fn on_stage_deinit(stage: InitStage) {
        if stage != InitStage::Scene {
            return;
        }
        let mut engine = Engine::singleton();
        if let Some(singleton) = engine.get_singleton(SINGLETON_NAME) {
            engine.unregister_singleton(SINGLETON_NAME);
            singleton.free();
        }
    }
}

struct Entry {
    script: PreparedScript,
    last_use: u64,
}

#[derive(GodotClass)]
#[class(base = Object)]
struct GameAlgoRuntime {
    base: Base<Object>,
    prepared: HashMap<String, Entry>,
    clock: u64,
    event_backend: EventBackend,
}

#[godot_api]
impl IObject for GameAlgoRuntime {
    fn init(base: Base<Object>) -> Self {
        Self {
            base,
            prepared: HashMap::new(),
            clock: 0,
            event_backend: EventBackend::new(),
        }
    }
}

#[godot_api]
impl GameAlgoRuntime {
    /// Always true once the extension loads. The GDScript SDK calls this to
    /// decide whether script-backed strategies can run at all.
    #[func]
    fn is_available(&self) -> bool {
        true
    }

    /// Parses a script once and keeps its context for later executions. The key
    /// is supplied by the SDK and already binds the script's version and hash.
    #[func]
    fn prepare(&mut self, script_key: GString, script: GString) -> bool {
        let key = script_key.to_string();
        if key.is_empty() {
            return false;
        }
        if self.prepared.contains_key(&key) {
            self.touch(&key);
            return true;
        }
        match PreparedScript::prepare(&script.to_string(), &RuntimeLimits::default()) {
            Ok(prepared) => {
                self.clock += 1;
                let last_use = self.clock;
                self.prepared.insert(
                    key,
                    Entry {
                        script: prepared,
                        last_use,
                    },
                );
                self.evict_if_needed();
                true
            }
            Err(_) => false,
        }
    }

    #[func]
    fn has_prepared(&self, script_key: GString) -> bool {
        self.prepared.contains_key(&script_key.to_string())
    }

    /// Runs a prepared script against JSON input and returns a JSON envelope.
    /// Every failure is reported as `{"status":"error"}`; the caller never gets
    /// a partial or invented result.
    #[func]
    fn execute_json(&mut self, script_key: GString, input_json: GString) -> GString {
        let key = script_key.to_string();
        if !self.prepared.contains_key(&key) {
            return error_envelope("script is not prepared");
        }
        let input: Value = match serde_json::from_str(&input_json.to_string()) {
            Ok(value) => value,
            Err(_) => return error_envelope("input is not valid JSON"),
        };
        self.touch(&key);
        let outcome = {
            let entry = match self.prepared.get(&key) {
                Some(entry) => entry,
                None => return error_envelope("script is not prepared"),
            };
            entry.script.execute(&input)
        };
        match outcome {
            Ok(result) => {
                let envelope = serde_json::json!({"status": "ok", "result": result});
                match serde_json::to_string(&envelope) {
                    Ok(encoded) => GString::from(encoded.as_str()),
                    Err(_) => error_envelope("script returned an unsupported value"),
                }
            }
            Err(error) => error_envelope(&error.to_string()),
        }
    }

    #[func]
    fn event_backend_configure(
        &self,
        storage_path: GString,
        endpoint: GString,
        game_key: GString,
        max_batch: i64,
        queue_limit: i64,
        platform: GString,
    ) -> bool {
        let configured = self.event_backend.configure(
            &storage_path.to_string(),
            &endpoint.to_string(),
            &game_key.to_string(),
            max_batch,
            queue_limit,
            &platform.to_string(),
        );
        #[cfg(target_os = "android")]
        if configured {
            android_lifecycle::register(self.event_backend.clone());
        }
        configured
    }

    #[func]
    fn event_backend_start_session(&self, event_json: GString, started_at_ms: i64) -> bool {
        self.event_backend
            .start_session(&event_json.to_string(), started_at_ms)
    }

    #[func]
    fn event_backend_enqueue(&self, event_json: GString) -> bool {
        self.event_backend.enqueue(&event_json.to_string())
    }

    #[func]
    fn event_backend_import(&self, events_json: GString) -> bool {
        self.event_backend.import_events(&events_json.to_string())
    }

    #[func]
    fn event_backend_bind_context(&self, session_id: GString, context_id: GString) -> bool {
        self.event_backend
            .bind_context(&session_id.to_string(), &context_id.to_string())
    }

    #[func]
    fn event_backend_clear(&self) -> bool {
        self.event_backend.clear()
    }

    #[func]
    fn event_backend_snapshot_json(&self) -> GString {
        GString::from(self.event_backend.snapshot_json().as_str())
    }

    #[func]
    fn event_backend_pending_count(&self) -> i64 {
        self.event_backend.pending_count()
    }

    #[func]
    fn event_backend_flush(&self, timeout_ms: i64) -> i64 {
        self.event_backend.start_flush(timeout_ms)
    }

    #[func]
    fn event_backend_result_json(&self, job_id: i64) -> GString {
        GString::from(self.event_backend.result_json(job_id).as_str())
    }

    #[func]
    fn event_backend_last_error(&self) -> GString {
        GString::from(self.event_backend.last_error().as_str())
    }

    fn touch(&mut self, key: &str) {
        self.clock += 1;
        let clock = self.clock;
        if let Some(entry) = self.prepared.get_mut(key) {
            entry.last_use = clock;
        }
    }

    fn evict_if_needed(&mut self) {
        while self.prepared.len() > MAX_PREPARED_SCRIPTS {
            let oldest = self
                .prepared
                .iter()
                .min_by_key(|(_, entry)| entry.last_use)
                .map(|(key, _)| key.clone());
            match oldest {
                Some(key) => {
                    self.prepared.remove(&key);
                }
                None => break,
            }
        }
    }
}

fn error_envelope(message: &str) -> GString {
    let envelope = serde_json::json!({"status": "error", "message": message});
    let encoded = serde_json::to_string(&envelope).unwrap_or_else(|_| {
        "{\"status\":\"error\",\"message\":\"script execution failed\"}".to_string()
    });
    GString::from(encoded.as_str())
}
