use serde_json::{Value, json};
use std::collections::{HashSet, VecDeque};
use std::error::Error as StdError;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const RESPONSE_BODY_LIMIT: u64 = 64 * 1024;
const MIN_TIMEOUT_MS: u64 = 1;
const MAX_TIMEOUT_MS: u64 = 60_000;
const HTTP_REQUEST_TIMEOUT_CAP_MS: u64 = 2_500;
const RESULT_HISTORY_LIMIT: usize = 16;

#[derive(Clone)]
pub(crate) struct EventBackend {
    inner: Arc<Mutex<Inner>>,
}

#[derive(Clone)]
struct Config {
    path: PathBuf,
    endpoint: String,
    game_key: String,
    max_batch: usize,
    queue_limit: usize,
    platform: String,
}

struct ActiveJob {
    id: u64,
    generation: u64,
    deadline: Instant,
}

struct Inner {
    config: Option<Config>,
    queue: Vec<Value>,
    active: Option<ActiveJob>,
    active_event_ids: HashSet<String>,
    next_job_id: u64,
    generation: u64,
    results: VecDeque<(u64, String)>,
    last_error: String,
}

impl EventBackend {
    pub(crate) fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner {
                config: None,
                queue: Vec::new(),
                active: None,
                active_event_ids: HashSet::new(),
                next_job_id: 1,
                generation: 0,
                results: VecDeque::new(),
                last_error: String::new(),
            })),
        }
    }

    pub(crate) fn configure(
        &self,
        storage_path: &str,
        endpoint: &str,
        game_key: &str,
        max_batch: i64,
        queue_limit: i64,
        platform: &str,
    ) -> bool {
        let result = (|| {
            if storage_path.is_empty()
                || !endpoint.starts_with("https://")
                || game_key.is_empty()
                || !(1..=100).contains(&max_batch)
                || queue_limit < max_batch
                || !matches!(platform, "android" | "ios")
            {
                return Err("invalid_native_event_configuration".to_string());
            }
            let path = PathBuf::from(storage_path);
            if !path.is_absolute() {
                return Err("native_event_path_not_absolute".to_string());
            }
            let queue = load_queue(&path)?;
            if queue.len() > queue_limit as usize {
                return Err("native_event_queue_exceeds_limit".to_string());
            }
            let mut inner = self
                .inner
                .lock()
                .map_err(|_| "native_event_lock_poisoned".to_string())?;
            if inner.active.is_some() {
                return Err("native_event_flush_in_progress".to_string());
            }
            inner.generation = inner.generation.wrapping_add(1);
            inner.config = Some(Config {
                path,
                endpoint: endpoint.to_string(),
                game_key: game_key.to_string(),
                max_batch: max_batch as usize,
                queue_limit: queue_limit as usize,
                platform: platform.to_string(),
            });
            inner.queue = queue;
            inner.active_event_ids.clear();
            inner.results.clear();
            inner.last_error.clear();
            Ok(())
        })();
        self.record(result)
    }

    pub(crate) fn enqueue(&self, event_json: &str) -> bool {
        let result = (|| {
            let event: Value = serde_json::from_str(event_json)
                .map_err(|_| "invalid_native_event_json".to_string())?;
            let event_id = valid_event_id(&event)?;
            let mut inner = self.lock()?;
            let config = inner
                .config
                .clone()
                .ok_or_else(|| "native_event_backend_unconfigured".to_string())?;
            if inner
                .queue
                .iter()
                .any(|candidate| event_id_of(candidate) == Some(&event_id))
            {
                return Ok(());
            }
            let mut candidate = inner.queue.clone();
            candidate.push(event);
            while candidate.len() > config.queue_limit {
                let removable = candidate.iter().position(|queued| {
                    event_id_of(queued)
                        .map(|id| !inner.active_event_ids.contains(id))
                        .unwrap_or(false)
                });
                let Some(index) = removable else {
                    return Err("native_event_queue_full".to_string());
                };
                if event_id_of(&candidate[index]) == Some(&event_id) {
                    return Err("native_event_queue_full".to_string());
                }
                candidate.remove(index);
            }
            persist_queue(&config.path, &candidate)?;
            inner.queue = candidate;
            Ok(())
        })();
        self.record(result)
    }

    pub(crate) fn import_events(&self, events_json: &str) -> bool {
        let result = (|| {
            let imported: Vec<Value> = serde_json::from_str(events_json)
                .map_err(|_| "invalid_native_event_import".to_string())?;
            for event in &imported {
                valid_event_id(event)?;
            }
            let mut inner = self.lock()?;
            let config = inner
                .config
                .clone()
                .ok_or_else(|| "native_event_backend_unconfigured".to_string())?;
            let mut candidate = inner.queue.clone();
            let mut ids: HashSet<String> = candidate
                .iter()
                .filter_map(|event| event_id_of(event).map(str::to_owned))
                .collect();
            for event in imported {
                let id = event_id_of(&event).unwrap_or_default().to_string();
                if ids.insert(id) {
                    candidate.push(event);
                }
            }
            if candidate.len() > config.queue_limit {
                candidate.drain(0..candidate.len() - config.queue_limit);
            }
            persist_queue(&config.path, &candidate)?;
            inner.queue = candidate;
            Ok(())
        })();
        self.record(result)
    }

    pub(crate) fn bind_context(&self, session_id: &str, context_id: &str) -> bool {
        let result = (|| {
            if session_id.is_empty() || context_id.is_empty() {
                return Err("invalid_native_event_context".to_string());
            }
            let mut inner = self.lock()?;
            let config = inner
                .config
                .clone()
                .ok_or_else(|| "native_event_backend_unconfigured".to_string())?;
            let mut candidate = inner.queue.clone();
            let mut changed = false;
            for event in &mut candidate {
                let Some(object) = event.as_object_mut() else {
                    continue;
                };
                if object.get("sessionId").and_then(Value::as_str) == Some(session_id)
                    && object.get("contextId").and_then(Value::as_str) == Some("")
                {
                    object.insert(
                        "contextId".to_string(),
                        Value::String(context_id.to_string()),
                    );
                    changed = true;
                }
            }
            if changed {
                persist_queue(&config.path, &candidate)?;
                inner.queue = candidate;
            }
            Ok(())
        })();
        self.record(result)
    }

    pub(crate) fn clear(&self) -> bool {
        let result = (|| {
            let mut inner = self.lock()?;
            let config = inner
                .config
                .clone()
                .ok_or_else(|| "native_event_backend_unconfigured".to_string())?;
            remove_queue(&config.path)?;
            inner.generation = inner.generation.wrapping_add(1);
            inner.queue.clear();
            inner.active_event_ids.clear();
            Ok(())
        })();
        self.record(result)
    }

    pub(crate) fn snapshot_json(&self) -> String {
        let Ok(inner) = self.inner.lock() else {
            return String::new();
        };
        serde_json::to_string(&inner.queue).unwrap_or_default()
    }

    pub(crate) fn pending_count(&self) -> i64 {
        self.inner
            .lock()
            .map(|inner| inner.queue.len() as i64)
            .unwrap_or(-1)
    }

    pub(crate) fn last_error(&self) -> String {
        self.inner
            .lock()
            .map(|inner| inner.last_error.clone())
            .unwrap_or_else(|_| "native_event_lock_poisoned".to_string())
    }

    pub(crate) fn start_flush(&self, timeout_ms: i64) -> i64 {
        let timeout_ms = timeout_ms.clamp(MIN_TIMEOUT_MS as i64, MAX_TIMEOUT_MS as i64) as u64;
        let mut inner = match self.inner.lock() {
            Ok(inner) => inner,
            Err(_) => return -1,
        };
        if inner.config.is_none() {
            inner.last_error = "native_event_backend_unconfigured".to_string();
            return -1;
        }
        let requested_deadline = Instant::now() + Duration::from_millis(timeout_ms);
        if let Some(active) = inner.active.as_mut() {
            active.deadline = active.deadline.min(requested_deadline);
            return active.id as i64;
        }
        let job_id = inner.next_job_id;
        inner.next_job_id = inner.next_job_id.wrapping_add(1).max(1);
        let generation = inner.generation;
        let platform = inner
            .config
            .as_ref()
            .map(|config| config.platform.clone())
            .unwrap_or_default();
        inner.active = Some(ActiveJob {
            id: job_id,
            generation,
            deadline: requested_deadline,
        });
        inner.last_error.clear();
        drop(inner);

        let shared = Arc::clone(&self.inner);
        let background_task = platform_support::begin_background_task(&platform);
        thread::Builder::new()
            .name("GameAlgoEventFlush".to_string())
            .spawn(move || {
                let _background_task = background_task;
                run_flush(shared, job_id, generation);
            })
            .map(|_| job_id as i64)
            .unwrap_or_else(|_| {
                if let Ok(mut inner) = self.inner.lock() {
                    inner.active = None;
                    inner.last_error = "native_event_worker_start_failed".to_string();
                }
                -1
            })
    }

    pub(crate) fn result_json(&self, job_id: i64) -> String {
        if job_id <= 0 {
            return String::new();
        }
        self.inner
            .lock()
            .ok()
            .and_then(|inner| {
                inner
                    .results
                    .iter()
                    .find(|(id, _)| *id == job_id as u64)
                    .map(|(_, result)| result.clone())
            })
            .unwrap_or_default()
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Inner>, String> {
        self.inner
            .lock()
            .map_err(|_| "native_event_lock_poisoned".to_string())
    }

    fn record(&self, result: Result<(), String>) -> bool {
        match result {
            Ok(()) => {
                if let Ok(mut inner) = self.inner.lock() {
                    inner.last_error.clear();
                }
                true
            }
            Err(error) => {
                if let Ok(mut inner) = self.inner.lock() {
                    inner.last_error = error;
                }
                false
            }
        }
    }
}

fn run_flush(shared: Arc<Mutex<Inner>>, job_id: u64, generation: u64) {
    let mut accepted_total = 0usize;
    let mut accepted_ids: Vec<String> = Vec::new();
    let mut accepted_events: Vec<Value> = Vec::new();
    loop {
        let (config, batch, deadline) = {
            let mut inner = match shared.lock() {
                Ok(inner) => inner,
                Err(_) => return,
            };
            let Some(active) = inner.active.as_ref() else {
                return;
            };
            let active_id = active.id;
            let active_generation = active.generation;
            let deadline = active.deadline;
            if active_id != job_id
                || active_generation != generation
                || inner.generation != generation
            {
                finish(
                    &mut inner,
                    job_id,
                    accepted_total,
                    accepted_ids,
                    accepted_events,
                    false,
                    false,
                    "flush_generation_changed",
                );
                return;
            }
            if Instant::now() >= deadline {
                finish(
                    &mut inner,
                    job_id,
                    accepted_total,
                    accepted_ids,
                    accepted_events,
                    false,
                    true,
                    "timeout",
                );
                return;
            }
            let config = match inner.config.clone() {
                Some(config) => config,
                None => {
                    finish(
                        &mut inner,
                        job_id,
                        accepted_total,
                        accepted_ids,
                        accepted_events,
                        false,
                        false,
                        "native_event_backend_unconfigured",
                    );
                    return;
                }
            };
            let batch: Vec<Value> = inner
                .queue
                .iter()
                .filter(|event| {
                    event
                        .get("contextId")
                        .and_then(Value::as_str)
                        .map(|context| !context.is_empty())
                        .unwrap_or(false)
                })
                .take(config.max_batch)
                .cloned()
                .collect();
            if batch.is_empty() {
                let pending = inner.queue.len();
                finish(
                    &mut inner,
                    job_id,
                    accepted_total,
                    accepted_ids,
                    accepted_events,
                    pending == 0,
                    false,
                    if pending == 0 {
                        ""
                    } else {
                        "context_not_ready"
                    },
                );
                return;
            }
            inner.active_event_ids = batch
                .iter()
                .filter_map(|event| event_id_of(event).map(str::to_owned))
                .collect();
            (config, batch, deadline)
        };

        let response = post_batch(
            &config,
            &batch,
            deadline.saturating_duration_since(Instant::now()),
        );
        let accepted = match response {
            Ok(accepted) if accepted == batch.len() => accepted,
            Ok(_) => {
                if let Ok(mut inner) = shared.lock() {
                    inner.active_event_ids.clear();
                    finish(
                        &mut inner,
                        job_id,
                        accepted_total,
                        accepted_ids,
                        accepted_events,
                        false,
                        false,
                        "accepted_count_mismatch",
                    );
                }
                return;
            }
            Err(error) => {
                if let Ok(mut inner) = shared.lock() {
                    inner.active_event_ids.clear();
                    let timed_out = error == "timeout";
                    finish(
                        &mut inner,
                        job_id,
                        accepted_total,
                        accepted_ids,
                        accepted_events,
                        false,
                        timed_out,
                        &error,
                    );
                }
                return;
            }
        };

        let batch_ids_in_order: Vec<String> = batch
            .iter()
            .filter_map(|event| event_id_of(event).map(str::to_owned))
            .collect();
        let batch_events_in_order: Vec<Value> = batch.iter().filter_map(acked_event_of).collect();
        let batch_ids: HashSet<String> = batch_ids_in_order.iter().cloned().collect();
        let mut inner = match shared.lock() {
            Ok(inner) => inner,
            Err(_) => return,
        };
        if inner.generation != generation {
            inner.active_event_ids.clear();
            finish(
                &mut inner,
                job_id,
                accepted_total,
                accepted_ids,
                accepted_events,
                false,
                false,
                "flush_generation_changed",
            );
            return;
        }
        let candidate: Vec<Value> = inner
            .queue
            .iter()
            .filter(|event| {
                event_id_of(event)
                    .map(|id| !batch_ids.contains(id))
                    .unwrap_or(true)
            })
            .cloned()
            .collect();
        if let Err(error) = persist_queue(&config.path, &candidate) {
            inner.active_event_ids.clear();
            accepted_ids.extend(batch_ids_in_order);
            accepted_events.extend(batch_events_in_order);
            finish(
                &mut inner,
                job_id,
                accepted_total + accepted,
                accepted_ids,
                accepted_events,
                false,
                false,
                &format!("server_acked_local_commit_failed:{error}"),
            );
            return;
        }
        inner.queue = candidate;
        inner.active_event_ids.clear();
        accepted_total += accepted;
        accepted_ids.extend(batch_ids_in_order);
        accepted_events.extend(batch_events_in_order);
    }
}

fn post_batch(config: &Config, batch: &[Value], timeout: Duration) -> Result<usize, String> {
    let request_timeout = timeout.min(Duration::from_millis(HTTP_REQUEST_TIMEOUT_CAP_MS));
    if request_timeout.is_zero() {
        return Err("timeout".to_string());
    }
    let agent = ureq::AgentBuilder::new()
        .redirects(0)
        .timeout(request_timeout)
        .timeout_connect(request_timeout)
        .build();
    let encoded = serde_json::to_string(&json!({"events": batch}))
        .map_err(|_| "request_invalid_json".to_string())?;
    let response = agent
        .post(&config.endpoint)
        .set("Accept", "application/json")
        .set("Content-Type", "application/json")
        .set("X-GameAlgo-Key", &config.game_key)
        .send_string(&encoded)
        .map_err(|error| match error {
            ureq::Error::Status(code, _) => format!("http_{code}"),
            ureq::Error::Transport(transport) if transport_timed_out(&transport) => {
                "timeout".to_string()
            }
            other => format!("transport:{other}"),
        })?;
    let mut body = Vec::new();
    response
        .into_reader()
        .take(RESPONSE_BODY_LIMIT + 1)
        .read_to_end(&mut body)
        .map_err(|error| {
            if matches!(
                error.kind(),
                std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
            ) {
                "timeout".to_string()
            } else {
                "response_read_failed".to_string()
            }
        })?;
    if body.len() as u64 > RESPONSE_BODY_LIMIT {
        return Err("response_body_too_large".to_string());
    }
    let value: Value =
        serde_json::from_slice(&body).map_err(|_| "invalid_event_response".to_string())?;
    if value.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err("event_rejected".to_string());
    }
    value
        .get("accepted")
        .and_then(Value::as_u64)
        .map(|accepted| accepted as usize)
        .ok_or_else(|| "invalid_event_response".to_string())
}

fn transport_timed_out(transport: &ureq::Transport) -> bool {
    let mut source = transport.source();
    while let Some(error) = source {
        if let Some(io_error) = error.downcast_ref::<std::io::Error>() {
            if matches!(
                io_error.kind(),
                std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
            ) {
                return true;
            }
        }
        source = error.source();
    }
    transport
        .message()
        .map(|message| message.to_ascii_lowercase().contains("timed out"))
        .unwrap_or(false)
}

fn finish(
    inner: &mut Inner,
    job_id: u64,
    accepted: usize,
    acked_event_ids: Vec<String>,
    acked_events: Vec<Value>,
    ok: bool,
    timed_out: bool,
    error: &str,
) {
    let acked_events_log =
        serde_json::to_string(&acked_events).unwrap_or_else(|_| "[]".to_string());
    let result = json!({
        "ok": ok,
        "accepted": accepted,
        "remaining": inner.queue.len(),
        "timed_out": timed_out,
        "error": error,
        "acked_event_ids": acked_event_ids,
        "acked_events": acked_events,
    });
    let encoded = serde_json::to_string(&result).unwrap_or_else(|_| {
        "{\"ok\":false,\"accepted\":0,\"remaining\":0,\"timed_out\":false,\"error\":\"result_encoding_failed\",\"acked_event_ids\":[],\"acked_events\":[]}".to_string()
    });
    inner.last_error = error.to_string();
    inner.results.push_back((job_id, encoded));
    while inner.results.len() > RESULT_HISTORY_LIMIT {
        inner.results.pop_front();
    }
    inner.active = None;
    inner.active_event_ids.clear();
    platform_support::log(&format!(
        "[GameAlgoSDK] flush {}: accepted={}, remaining={}, acked_events={}, error={}",
        if ok { "ok" } else { "failed" },
        accepted,
        inner.queue.len(),
        acked_events_log,
        if error.is_empty() { "<none>" } else { error }
    ));
}

fn valid_event_id(event: &Value) -> Result<String, String> {
    let object = event
        .as_object()
        .ok_or_else(|| "native_event_not_object".to_string())?;
    for field in [
        "eventId",
        "contextId",
        "userId",
        "sessionId",
        "eventType",
        "timestamp",
        "createdLocalAt",
    ] {
        if !object.get(field).map(Value::is_string).unwrap_or(false) {
            return Err(format!("native_event_missing_{field}"));
        }
    }
    let event_id = object
        .get("eventId")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if event_id.is_empty()
        || object
            .get("userId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .is_empty()
        || object
            .get("sessionId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .is_empty()
        || object
            .get("eventType")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .is_empty()
        || !object
            .get("isDebug")
            .map(Value::is_boolean)
            .unwrap_or(false)
        || !object.get("payload").map(Value::is_object).unwrap_or(false)
    {
        return Err("invalid_native_event".to_string());
    }
    Ok(event_id.to_string())
}

fn event_id_of(event: &Value) -> Option<&str> {
    event.get("eventId").and_then(Value::as_str)
}

fn acked_event_of(event: &Value) -> Option<Value> {
    Some(json!({
        "event_id": event_id_of(event)?,
        "event_type": event.get("eventType").and_then(Value::as_str)?,
    }))
}

fn load_queue(path: &Path) -> Result<Vec<Value>, String> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let bytes = fs::read(path).map_err(|error| format!("native_event_read_failed:{error}"))?;
    let queue: Vec<Value> =
        serde_json::from_slice(&bytes).map_err(|_| "native_event_storage_invalid".to_string())?;
    for event in &queue {
        valid_event_id(event)?;
    }
    Ok(queue)
}

fn persist_queue(path: &Path, queue: &[Value]) -> Result<(), String> {
    if queue.is_empty() {
        return remove_queue(path);
    }
    let parent = path
        .parent()
        .ok_or_else(|| "native_event_path_invalid".to_string())?;
    let parent_existed = parent.exists();
    fs::create_dir_all(parent).map_err(|error| format!("native_event_directory_failed:{error}"))?;
    if !parent_existed {
        if let Some(grandparent) = parent.parent() {
            sync_parent(grandparent);
        }
    }
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temporary = parent.join(format!(
        ".{}.{}.tmp",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("events"),
        nonce
    ));
    let encoded =
        serde_json::to_vec(queue).map_err(|_| "native_event_encoding_failed".to_string())?;
    let write_result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|error| format!("native_event_temp_open_failed:{error}"))?;
        file.write_all(&encoded)
            .map_err(|error| format!("native_event_write_failed:{error}"))?;
        file.sync_all()
            .map_err(|error| format!("native_event_sync_failed:{error}"))?;
        fs::rename(&temporary, path)
            .map_err(|error| format!("native_event_commit_failed:{error}"))?;
        sync_parent(parent);
        Ok(())
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    write_result
}

fn remove_queue(path: &Path) -> Result<(), String> {
    if path.exists() {
        fs::remove_file(path).map_err(|error| format!("native_event_remove_failed:{error}"))?;
        if let Some(parent) = path.parent() {
            sync_parent(parent);
        }
    }
    Ok(())
}

fn sync_parent(parent: &Path) {
    if let Ok(directory) = File::open(parent) {
        let _ = directory.sync_all();
    }
}

mod platform_support {
    pub(super) struct BackgroundTask(Option<usize>);

    impl Drop for BackgroundTask {
        fn drop(&mut self) {
            if let Some(identifier) = self.0.take() {
                end_ios_background_task(identifier);
            }
        }
    }

    pub(super) fn begin_background_task(platform: &str) -> BackgroundTask {
        BackgroundTask(if platform == "ios" {
            begin_ios_background_task()
        } else {
            None
        })
    }

    #[cfg(target_os = "ios")]
    fn begin_ios_background_task() -> Option<usize> {
        use std::ffi::{CString, c_char, c_void};
        #[link(name = "objc")]
        unsafe extern "C" {
            fn objc_getClass(name: *const c_char) -> *mut c_void;
            fn sel_registerName(name: *const c_char) -> *mut c_void;
            fn objc_msgSend();
        }
        unsafe {
            let class_name = CString::new("UIApplication").ok()?;
            let shared_name = CString::new("sharedApplication").ok()?;
            let begin_name = CString::new("beginBackgroundTaskWithExpirationHandler:").ok()?;
            let class = objc_getClass(class_name.as_ptr());
            if class.is_null() {
                return None;
            }
            let shared: extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void =
                std::mem::transmute(objc_msgSend as *const ());
            let application = shared(class, sel_registerName(shared_name.as_ptr()));
            if application.is_null() {
                return None;
            }
            let begin: extern "C" fn(*mut c_void, *mut c_void, *mut c_void) -> usize =
                std::mem::transmute(objc_msgSend as *const ());
            let identifier = begin(
                application,
                sel_registerName(begin_name.as_ptr()),
                std::ptr::null_mut(),
            );
            (identifier != usize::MAX).then_some(identifier)
        }
    }

    #[cfg(not(target_os = "ios"))]
    fn begin_ios_background_task() -> Option<usize> {
        None
    }

    #[cfg(target_os = "ios")]
    fn end_ios_background_task(identifier: usize) {
        use std::ffi::{CString, c_char, c_void};
        #[link(name = "objc")]
        unsafe extern "C" {
            fn objc_getClass(name: *const c_char) -> *mut c_void;
            fn sel_registerName(name: *const c_char) -> *mut c_void;
            fn objc_msgSend();
        }
        unsafe {
            let Ok(class_name) = CString::new("UIApplication") else {
                return;
            };
            let Ok(shared_name) = CString::new("sharedApplication") else {
                return;
            };
            let Ok(end_name) = CString::new("endBackgroundTask:") else {
                return;
            };
            let class = objc_getClass(class_name.as_ptr());
            if class.is_null() {
                return;
            }
            let shared: extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void =
                std::mem::transmute(objc_msgSend as *const ());
            let application = shared(class, sel_registerName(shared_name.as_ptr()));
            if application.is_null() {
                return;
            }
            let end: extern "C" fn(*mut c_void, *mut c_void, usize) =
                std::mem::transmute(objc_msgSend as *const ());
            end(application, sel_registerName(end_name.as_ptr()), identifier);
        }
    }

    #[cfg(not(target_os = "ios"))]
    fn end_ios_background_task(_identifier: usize) {}

    #[cfg(target_os = "android")]
    pub(super) fn log(message: &str) {
        use std::ffi::{CString, c_char};
        #[link(name = "log")]
        unsafe extern "C" {
            fn __android_log_write(priority: i32, tag: *const c_char, text: *const c_char) -> i32;
        }
        if let (Ok(tag), Ok(text)) = (CString::new("GameAlgoSDK"), CString::new(message)) {
            unsafe {
                __android_log_write(4, tag.as_ptr(), text.as_ptr());
            }
        }
    }

    #[cfg(target_os = "ios")]
    pub(super) fn log(message: &str) {
        use std::ffi::{CString, c_char, c_void};
        #[link(name = "objc")]
        unsafe extern "C" {
            fn objc_getClass(name: *const c_char) -> *mut c_void;
            fn sel_registerName(name: *const c_char) -> *mut c_void;
            fn objc_msgSend();
        }
        #[link(name = "Foundation", kind = "framework")]
        unsafe extern "C" {
            fn NSLog(format: *mut c_void, ...);
        }
        unsafe {
            let Ok(class_name) = CString::new("NSString") else {
                return;
            };
            let Ok(selector_name) = CString::new("stringWithUTF8String:") else {
                return;
            };
            let Ok(format_text) = CString::new("%@") else {
                return;
            };
            let Ok(message_text) = CString::new(message) else {
                return;
            };
            let class = objc_getClass(class_name.as_ptr());
            if class.is_null() {
                return;
            }
            let make_string: extern "C" fn(*mut c_void, *mut c_void, *const c_char) -> *mut c_void =
                std::mem::transmute(objc_msgSend as *const ());
            let selector = sel_registerName(selector_name.as_ptr());
            let format = make_string(class, selector, format_text.as_ptr());
            let text = make_string(class, selector, message_text.as_ptr());
            if !format.is_null() && !text.is_null() {
                NSLog(format, text);
            }
        }
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    pub(super) fn log(message: &str) {
        eprintln!("{message}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(id: &str, session: &str, context: &str) -> Value {
        json!({
            "eventId": id,
            "contextId": context,
            "userId": "user",
            "sessionId": session,
            "eventType": "ad_view",
            "isDebug": false,
            "timestamp": "2026-01-01T00:00:00.000Z",
            "createdLocalAt": "2026-01-01T08:00:00.000+08:00",
            "payload": {}
        })
    }

    fn temporary_path(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "gamealgo-godot-{name}-{}-{}.json",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ))
    }

    #[test]
    fn queue_is_durable_and_context_binding_is_atomic() {
        let path = temporary_path("queue");
        let backend = EventBackend::new();
        assert!(backend.configure(
            path.to_str().unwrap(),
            "https://gamealgo.example/v1/events/batch",
            "ga_live_test",
            100,
            1000,
            "android"
        ));
        assert!(backend.enqueue(&event("event-1", "session-1", "").to_string()));
        assert!(backend.bind_context("session-1", "context-1"));

        let restored = EventBackend::new();
        assert!(restored.configure(
            path.to_str().unwrap(),
            "https://gamealgo.example/v1/events/batch",
            "ga_live_test",
            100,
            1000,
            "android"
        ));
        let queue: Vec<Value> = serde_json::from_str(&restored.snapshot_json()).unwrap();
        assert_eq!(queue.len(), 1);
        assert_eq!(queue[0]["eventId"], "event-1");
        assert_eq!(queue[0]["contextId"], "context-1");
        assert!(restored.clear());
        assert!(!path.exists());
    }

    #[test]
    fn import_deduplicates_and_queue_limit_keeps_newest() {
        let path = temporary_path("import");
        let backend = EventBackend::new();
        assert!(backend.configure(
            path.to_str().unwrap(),
            "https://gamealgo.example/v1/events/batch",
            "ga_live_test",
            2,
            2,
            "ios"
        ));
        assert!(
            backend.import_events(
                &json!([
                    event("event-1", "session", "context"),
                    event("event-2", "session", "context"),
                    event("event-1", "session", "context"),
                    event("event-3", "session", "context")
                ])
                .to_string()
            )
        );
        let queue: Vec<Value> = serde_json::from_str(&backend.snapshot_json()).unwrap();
        assert_eq!(queue.len(), 2);
        assert_eq!(queue[0]["eventId"], "event-2");
        assert_eq!(queue[1]["eventId"], "event-3");
        assert!(backend.clear());
    }

    #[test]
    fn acknowledged_event_summary_contains_only_id_and_type() {
        let summary = acked_event_of(&event("event-ad", "session", "context")).unwrap();
        assert_eq!(
            summary,
            json!({"event_id": "event-ad", "event_type": "ad_view"})
        );
    }

    #[test]
    fn detached_flush_reports_unbound_events_without_deleting_them() {
        let path = temporary_path("unbound-flush");
        let backend = EventBackend::new();
        assert!(backend.configure(
            path.to_str().unwrap(),
            "https://gamealgo.example/v1/events/batch",
            "ga_live_test",
            100,
            1000,
            "android"
        ));
        assert!(backend.enqueue(&event("event-unbound", "session-1", "").to_string()));
        let job_id = backend.start_flush(2_500);
        assert!(job_id > 0);
        let encoded = (0..100)
            .find_map(|_| {
                let result = backend.result_json(job_id);
                if result.is_empty() {
                    thread::sleep(Duration::from_millis(1));
                    None
                } else {
                    Some(result)
                }
            })
            .expect("detached flush should finish");
        let result: Value = serde_json::from_str(&encoded).unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(result["accepted"], 0);
        assert_eq!(result["remaining"], 1);
        assert_eq!(result["timed_out"], false);
        assert_eq!(result["error"], "context_not_ready");
        assert_eq!(backend.pending_count(), 1);
        assert!(backend.clear());
    }
}
