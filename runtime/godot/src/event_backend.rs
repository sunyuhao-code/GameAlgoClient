use serde::{Deserialize, Serialize};
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
    session: Option<Session>,
    session_tracking: bool,
    foreground: bool,
}

#[derive(Clone, Serialize, Deserialize)]
struct Session {
    event: Value,
    started_at_ms: u64,
    last_seen_ms: u64,
    open: bool,
    // `open` is rearmed on foreground for another background/kill report.
    // Remember a committed end separately so an explicit rotation after resume
    // does not extend the old session across the time spent in the background.
    #[serde(default)]
    has_end: bool,
    // None is the pre-sampling journal format; retain its saved estimate only
    // when recovering that old record. All newly started sessions use Some(0).
    #[serde(default)]
    duration_ms: Option<u64>,
    #[serde(skip)]
    sample_at_ms: u64,
    #[serde(skip)]
    sample_foreground: bool,
}

#[derive(Serialize, Deserialize)]
struct StoredState {
    version: u32,
    events: Vec<Value>,
    session: Option<Session>,
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
                session: None,
                session_tracking: false,
                foreground: true,
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
            let (queue, session) = load_state(&path)?;
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
            inner.session = session;
            // Consent must be confirmed before recovery or lifecycle collection.
            inner.session_tracking = false;
            inner.foreground = true;
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
            candidate.push(event.clone());
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
            let mut session = inner.session.clone();
            if event.get("eventType").and_then(Value::as_str) == Some("session_end") {
                if let Some(session) = session.as_mut() {
                    if event.get("sessionId") == session.event.get("sessionId") {
                        session.open = false;
                        session.has_end = true;
                    }
                }
            }
            persist_state(&config.path, &candidate, session.as_ref())?;
            inner.queue = candidate;
            inner.session = session;
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
            persist_state(&config.path, &candidate, inner.session.as_ref())?;
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
            let mut session = inner.session.clone();
            if let Some(session) = session.as_mut() {
                if session.event["sessionId"].as_str() == Some(session_id) {
                    session.event["contextId"] = json!(context_id);
                    changed = true;
                }
            }
            if changed {
                persist_state(&config.path, &candidate, session.as_ref())?;
                inner.queue = candidate;
                inner.session = session;
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
            inner.session = None;
            inner.session_tracking = false;
            inner.active_event_ids.clear();
            Ok(())
        })();
        self.record(result)
    }

    /// Starts collection only after measurement consent. Closing/recovering the
    /// previous session and replacing its marker is one durable transaction.
    pub(crate) fn start_session(&self, event_json: &str, started_at_ms: i64) -> bool {
        let result = (|| {
            let event: Value = serde_json::from_str(event_json)
                .map_err(|_| "invalid_native_session_json".to_string())?;
            valid_event_id(&event)?;
            if event["eventType"] != "session_end" || started_at_ms <= 0 {
                return Err("invalid_native_session".to_string());
            }
            let mut inner = self.lock()?;
            let config = inner
                .config
                .clone()
                .ok_or_else(|| "native_event_backend_unconfigured".to_string())?;
            if inner.session_tracking
                && inner
                    .session
                    .as_ref()
                    .is_some_and(|previous| previous.event["sessionId"] == event["sessionId"])
            {
                return Ok(());
            }
            let mut candidate = inner.queue.clone();
            let mut closed_session = None;
            if let Some(previous) = inner.session.as_ref() {
                let reason = if !inner.session_tracking && previous.open {
                    Some("process_restart")
                } else if inner.session_tracking && !previous.has_end {
                    Some("new_session")
                } else {
                    None
                };
                if let Some(reason) = reason {
                    let mut ended = previous.clone();
                    if reason == "new_session" {
                        ended.last_seen_ms = started_at_ms as u64;
                        ended.event["timestamp"] = event["timestamp"].clone();
                        ended.event["createdLocalAt"] = event["createdLocalAt"].clone();
                    }
                    push_session_end(
                        &inner,
                        &config,
                        &mut candidate,
                        session_end(&ended, reason, reason == "process_restart"),
                    )?;
                    closed_session = Some((previous.event["sessionId"].clone(), reason));
                }
            }
            let session = Session {
                event,
                started_at_ms: started_at_ms as u64,
                last_seen_ms: started_at_ms as u64,
                open: inner.foreground,
                has_end: false,
                duration_ms: Some(0),
                sample_at_ms: started_at_ms as u64,
                sample_foreground: inner.foreground,
            };
            persist_state(&config.path, &candidate, Some(&session))?;
            inner.queue = candidate;
            inner.session = Some(session);
            inner.session_tracking = true;
            if let Some((session_id, reason)) = closed_session {
                platform_support::log(&format!(
                    "[GameAlgoSDK] session_end persisted: sessionId={}, reason={reason}, estimated={}",
                    session_id.as_str().unwrap_or_default(),
                    reason == "process_restart"
                ));
            }
            Ok(())
        })();
        self.record(result)
    }

    /// Called directly from the platform UI thread, without entering Godot or
    /// relying on SceneTree frames. Timestamps are supplied by the bridge so
    /// local UTC offsets remain correct while the game is paused under an ad.
    #[cfg(any(target_os = "android", target_os = "ios", test))]
    pub(crate) fn lifecycle(
        &self,
        foreground: bool,
        now_ms: i64,
        timestamp: &str,
        created_local_at: &str,
        next_event_id: &str,
    ) -> bool {
        let mut should_flush = false;
        let result = (|| {
            if now_ms <= 0 || timestamp.is_empty() || created_local_at.is_empty() {
                return Err("invalid_native_lifecycle_time".to_string());
            }
            let mut inner = self.lock()?;
            let changed = inner.foreground != foreground;
            if !inner.session_tracking {
                inner.foreground = foreground;
                return Ok(());
            }
            let config = inner
                .config
                .clone()
                .ok_or_else(|| "native_event_backend_unconfigured".to_string())?;
            let mut session = inner
                .session
                .clone()
                .ok_or_else(|| "native_session_missing".to_string())?;
            sample_duration(&mut session, foreground, now_ms as u64);
            session.last_seen_ms = now_ms as u64;
            session.event["timestamp"] = json!(timestamp);
            session.event["createdLocalAt"] = json!(created_local_at);
            let mut candidate = inner.queue.clone();
            if changed && foreground {
                if next_event_id.is_empty() {
                    return Err("invalid_native_session_event_id".to_string());
                }
                session.event["eventId"] = json!(next_event_id);
                session.open = true;
            } else if changed {
                let event = session_end(&session, "background", false);
                push_session_end(&inner, &config, &mut candidate, event)?;
                session.open = false;
                session.has_end = true;
            }
            persist_state(&config.path, &candidate, Some(&session))?;
            inner.queue = candidate;
            inner.session = Some(session);
            inner.foreground = foreground;
            should_flush = changed && !foreground;
            if should_flush {
                platform_support::log(&format!(
                    "[GameAlgoSDK] session_end persisted: sessionId={}, reason=background",
                    inner
                        .session
                        .as_ref()
                        .and_then(|s| s.event["sessionId"].as_str())
                        .unwrap_or_default()
                ));
            }
            Ok(())
        })();
        let accepted = self.record(result);
        if accepted && should_flush {
            self.start_flush(2_500);
        }
        accepted
    }

    /// No persistence, event creation or upload on the one-second sampling path.
    #[cfg(test)]
    pub(crate) fn sample_duration(&self, foreground: bool, now_ms: i64) {
        if now_ms <= 0 {
            return;
        }
        if let Ok(mut inner) = self.inner.lock() {
            if inner.session_tracking {
                if let Some(session) = inner.session.as_mut() {
                    sample_duration(session, foreground, now_ms as u64);
                }
            }
        }
    }

    #[cfg(any(target_os = "android", target_os = "ios", test))]
    pub(crate) fn sample_duration_at(
        &self,
        foreground: bool,
        now_ms: i64,
        timestamp: &str,
        local: &str,
    ) {
        if now_ms <= 0 {
            return;
        }
        if let Ok(mut inner) = self.inner.lock() {
            if inner.session_tracking {
                if let Some(session) = inner.session.as_mut() {
                    sample_duration(session, foreground, now_ms as u64);
                    if foreground {
                        session.last_seen_ms = now_ms as u64;
                        session.event["timestamp"] = json!(timestamp);
                        session.event["createdLocalAt"] = json!(local);
                    }
                }
            }
        }
    }

    pub(crate) fn duration_ms(&self) -> i64 {
        self.inner
            .lock()
            .ok()
            .and_then(|inner| {
                if !inner.session_tracking {
                    return None;
                }
                inner
                    .session
                    .as_ref()
                    .and_then(|session| session.duration_ms)
            })
            .unwrap_or(0)
            .min(i64::MAX as u64) as i64
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
    run_flush_with_post(shared, job_id, generation, post_batch);
}

fn run_flush_with_post(
    shared: Arc<Mutex<Inner>>,
    job_id: u64,
    generation: u64,
    mut post: impl FnMut(&Config, &[Value], Duration) -> Result<usize, String>,
) {
    let mut accepted_total = 0usize;
    let mut accepted_ids: Vec<String> = Vec::new();
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

        let response = post(
            &config,
            &batch,
            deadline.saturating_duration_since(Instant::now()),
        );
        let accepted = match response {
            Ok(accepted) => accepted,
            Err(error) => {
                if let Ok(mut inner) = shared.lock() {
                    inner.active_event_ids.clear();
                    let timed_out = error == "timeout";
                    finish(
                        &mut inner,
                        job_id,
                        accepted_total,
                        accepted_ids,
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
        if let Err(error) = persist_state(&config.path, &candidate, inner.session.as_ref()) {
            inner.active_event_ids.clear();
            accepted_ids.extend(batch_ids_in_order);
            finish(
                &mut inner,
                job_id,
                accepted_total + accepted,
                accepted_ids,
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
    let accepted = accepted_batch_count(&value, batch.len())?;
    if accepted < batch.len() {
        platform_support::log(&format!(
            "[GameAlgoSDK] flush batch completed: sent={}, accepted={}, notAccepted={}",
            batch.len(),
            accepted,
            batch.len() - accepted
        ));
        if let Some(rows) = value.get("rejected").and_then(Value::as_array) {
            for row in rows
                .iter()
                .filter(|row| row.is_object())
                .take(batch.len() - accepted)
            {
                platform_support::log(&format!("[GameAlgoSDK] flush event rejected: {row}"));
            }
        }
    }
    Ok(accepted)
}

fn accepted_batch_count(value: &Value, batch_size: usize) -> Result<usize, String> {
    if value.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err("event_rejected".to_string());
    }
    let accepted = value
        .get("accepted")
        .and_then(Value::as_f64)
        .filter(|count| {
            count.is_finite()
                && *count >= 0.0
                && *count <= batch_size as f64
                && count.fract() == 0.0
        })
        .map(|count| count as usize)
        .ok_or_else(|| "invalid_event_response".to_string())?;
    // Do not let incomplete or malformed optional rejection metadata turn an
    // already processed batch into an endless whole-batch replay.
    if accepted > 0 {
        return Ok(accepted);
    }
    if value
        .get("rejected")
        .and_then(Value::as_array)
        .is_some_and(|rows| rows.len() == batch_size && rows.iter().all(Value::is_object))
    {
        return Ok(0);
    }
    Err("accepted_count_mismatch".to_string())
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
    ok: bool,
    timed_out: bool,
    error: &str,
) {
    let result = json!({
        "ok": ok,
        "accepted": accepted,
        "remaining": inner.queue.len(),
        "timed_out": timed_out,
        "error": error,
        "acked_event_ids": acked_event_ids,
    });
    let encoded = serde_json::to_string(&result).unwrap_or_else(|_| {
        "{\"ok\":false,\"accepted\":0,\"remaining\":0,\"timed_out\":false,\"error\":\"result_encoding_failed\",\"acked_event_ids\":[]}".to_string()
    });
    inner.last_error = error.to_string();
    inner.results.push_back((job_id, encoded));
    while inner.results.len() > RESULT_HISTORY_LIMIT {
        inner.results.pop_front();
    }
    inner.active = None;
    inner.active_event_ids.clear();
    platform_support::log(&format!(
        "[GameAlgoSDK] flush {}: accepted={}, remaining={}, error={}",
        if ok { "ok" } else { "failed" },
        accepted,
        inner.queue.len(),
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

#[cfg(any(target_os = "android", target_os = "ios", test))]
fn sample_duration(session: &mut Session, foreground: bool, now_ms: u64) {
    if foreground && session.sample_foreground {
        session.duration_ms = Some(
            session
                .duration_ms
                .unwrap_or(0)
                .saturating_add(now_ms.saturating_sub(session.sample_at_ms).min(1000)),
        );
    }
    session.sample_at_ms = now_ms;
    session.sample_foreground = foreground;
}

fn session_end(session: &Session, reason: &str, recovered: bool) -> Value {
    let mut event = session.event.clone();
    event["payload"] = json!({
        "reason": reason,
        "recovered": recovered,
        "endTimeEstimated": recovered,
        "sessionDurationMs": session.duration_ms.unwrap_or_else(|| session.last_seen_ms.saturating_sub(session.started_at_ms)),
    });
    event
}

fn push_session_end(
    inner: &Inner,
    config: &Config,
    candidate: &mut Vec<Value>,
    event: Value,
) -> Result<(), String> {
    if candidate
        .iter()
        .any(|queued| event_id_of(queued) == event_id_of(&event))
    {
        return Ok(());
    }
    if candidate.len() >= config.queue_limit {
        let index = candidate
            .iter()
            .position(|queued| {
                event_id_of(queued).is_some_and(|id| !inner.active_event_ids.contains(id))
            })
            .ok_or_else(|| "native_event_queue_full".to_string())?;
        candidate.remove(index);
    }
    candidate.push(event);
    Ok(())
}

fn load_state(path: &Path) -> Result<(Vec<Value>, Option<Session>), String> {
    if !path.exists() {
        return Ok((Vec::new(), None));
    }
    let bytes = fs::read(path).map_err(|error| format!("native_event_read_failed:{error}"))?;
    let value: Value =
        serde_json::from_slice(&bytes).map_err(|_| "native_event_storage_invalid".to_string())?;
    // Accept the original array-only queue without losing any event IDs.
    let (queue, session): (Vec<Value>, Option<Session>) = if value.is_array() {
        (
            serde_json::from_value(value)
                .map_err(|_| "native_event_storage_invalid".to_string())?,
            None,
        )
    } else {
        let state: StoredState = serde_json::from_value(value)
            .map_err(|_| "native_event_storage_invalid".to_string())?;
        if state.version != 2 {
            return Err("native_event_storage_version_invalid".to_string());
        }
        if let Some(session) = state.session.as_ref() {
            valid_event_id(&session.event)?;
            if session.started_at_ms == 0 || session.event["eventType"] != "session_end" {
                return Err("invalid_native_session".to_string());
            }
        }
        (state.events, state.session)
    };
    for event in &queue {
        valid_event_id(event)?;
    }
    Ok((queue, session))
}

fn persist_state(path: &Path, queue: &[Value], session: Option<&Session>) -> Result<(), String> {
    if queue.is_empty() && session.is_none() {
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
    let encoded = if session.is_some() {
        serde_json::to_vec(&json!({"version": 2, "events": queue, "session": session}))
    } else {
        // Keep the original wire format for backends without session tracking.
        serde_json::to_vec(queue)
    }
    .map_err(|_| "native_event_encoding_failed".to_string())?;
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

    fn configured(path: &Path) -> EventBackend {
        let backend = EventBackend::new();
        assert!(backend.configure(
            path.to_str().unwrap(),
            "https://gamealgo.example/v1/events/batch",
            "ga_live_test",
            100,
            1000,
            "android"
        ));
        backend
    }

    fn test_flush(
        backend: &EventBackend,
        post: impl FnMut(&Config, &[Value], Duration) -> Result<usize, String>,
    ) -> Value {
        let (job_id, generation) = reserve_test_flush(backend);
        run_flush_with_post(Arc::clone(&backend.inner), job_id, generation, post);
        serde_json::from_str(&backend.result_json(i64::try_from(job_id).unwrap())).unwrap()
    }

    // Reserve a worker without making HTTP requests. Lifecycle-triggered flush
    // calls coalesce into this job; the test can then supply its own transport.
    fn reserve_test_flush(backend: &EventBackend) -> (u64, u64) {
        let mut inner = backend.lock().unwrap();
        assert!(inner.active.is_none());
        let id = inner.next_job_id;
        inner.next_job_id += 1;
        let generation = inner.generation;
        inner.active = Some(ActiveJob {
            id,
            generation,
            deadline: Instant::now() + Duration::from_secs(5),
        });
        (id, generation)
    }

    #[test]
    fn batch_completion_matches_shared_maker_and_gdscript_fixtures() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../protocol/fixtures/event-batch-ack.json"
        ))
        .unwrap();
        let batch_size = fixture["batchSize"].as_u64().unwrap() as usize;
        for case in fixture["cases"].as_array().unwrap() {
            let result = accepted_batch_count(&case["response"], batch_size);
            assert_eq!(
                result.is_ok(),
                case["terminal"].as_bool().unwrap(),
                "{}: {result:?}",
                case["name"]
            );
            if let Ok(accepted) = result {
                assert_eq!(
                    accepted,
                    case["accepted"].as_u64().unwrap() as usize,
                    "{}",
                    case["name"]
                );
            }
        }
    }

    #[test]
    fn positive_partial_batch_is_removed_without_replaying_or_losing_new_events() {
        let path = temporary_path("partial-batch");
        let backend = configured(&path);
        backend.lock().unwrap().config.as_mut().unwrap().max_batch = 2;
        for id in ["first", "second"] {
            assert!(backend.enqueue(&event(id, "session", "context").to_string()));
        }
        let mut sent = Vec::new();
        let result = test_flush(&backend, |_, batch, _| {
            sent.push(
                batch
                    .iter()
                    .map(|e| e["eventId"].as_str().unwrap().to_owned())
                    .collect::<Vec<_>>(),
            );
            if sent.len() == 1 {
                // Enqueue while the first batch is in flight. Completing that
                // batch must not discard this unrelated new event.
                assert!(backend.enqueue(&event("third", "session", "context").to_string()));
            }
            accepted_batch_count(&json!({"ok": true, "accepted": 1}), batch.len())
        });
        assert_eq!(sent, vec![vec!["first", "second"], vec!["third"]]);
        assert_eq!(result["ok"], true);
        assert_eq!(result["accepted"], 2); // not the three dequeued events
        assert_eq!(result["remaining"], 0);
        assert_eq!(
            result["acked_event_ids"],
            json!(["first", "second", "third"])
        );
        assert_eq!(configured(&path).pending_count(), 0);
    }

    #[test]
    fn zero_with_complete_rejections_is_terminal_but_zero_without_them_retries() {
        let path = temporary_path("zero-batch");
        let backend = configured(&path);
        let events = vec![
            event("first", "session", "context"),
            event("second", "session", "context"),
        ];
        assert!(backend.import_events(&serde_json::to_string(&events).unwrap()));
        let result = test_flush(&backend, |_, batch, _| {
            accepted_batch_count(&json!({"ok": true, "accepted": 0}), batch.len())
        });
        assert_eq!(result["ok"], false);
        assert_eq!(result["error"], "accepted_count_mismatch");
        assert_eq!(result["remaining"], 2);
        assert_eq!(load_state(&path).unwrap().0, events);
        let result = test_flush(&backend, |_, batch, _| {
            accepted_batch_count(
                &json!({"ok": true, "accepted": 0,
                "rejected": [{"index": 0}, {"index": 1}]}),
                batch.len(),
            )
        });
        assert_eq!(result["ok"], true);
        assert_eq!(result["accepted"], 0);
        assert_eq!(result["remaining"], 0);
        assert_eq!(configured(&path).pending_count(), 0);
    }

    #[test]
    fn later_network_failure_preserves_only_the_unfinished_batch_across_restart() {
        let path = temporary_path("partial-then-timeout");
        let backend = configured(&path);
        backend.lock().unwrap().config.as_mut().unwrap().max_batch = 2;
        for id in ["first", "second", "third", "fourth"] {
            assert!(backend.enqueue(&event(id, "session", "context").to_string()));
        }
        let mut calls = 0;
        let result = test_flush(&backend, |_, batch, _| {
            calls += 1;
            if calls == 1 {
                accepted_batch_count(&json!({"ok": true, "accepted": 1}), batch.len())
            } else {
                Err("timeout".to_string())
            }
        });
        assert_eq!(calls, 2);
        assert_eq!(result["ok"], false);
        assert_eq!(result["timed_out"], true);
        assert_eq!(result["accepted"], 1);
        assert_eq!(result["acked_event_ids"], json!(["first", "second"]));
        assert_eq!(result["remaining"], 2);
        let restored = configured(&path);
        let result = test_flush(&restored, |_, batch, _| {
            assert_eq!(
                batch
                    .iter()
                    .map(|e| e["eventId"].as_str().unwrap())
                    .collect::<Vec<_>>(),
                vec!["third", "fourth"]
            );
            accepted_batch_count(&json!({"ok": true, "accepted": 1}), batch.len())
        });
        assert_eq!(result["ok"], true);
        assert_eq!(result["accepted"], 1);
        assert_eq!(result["remaining"], 0);
    }

    #[test]
    fn partial_batch_local_commit_failure_keeps_the_durable_queue_for_retry() {
        let path = temporary_path("partial-commit");
        let backend = configured(&path);
        assert!(backend.enqueue(&event("first", "session", "context").to_string()));
        assert!(backend.enqueue(&event("second", "session", "context").to_string()));
        let saved = path.with_extension("saved");
        fs::rename(&path, &saved).unwrap();
        fs::create_dir(&path).unwrap();
        let result = test_flush(&backend, |_, batch, _| {
            accepted_batch_count(&json!({"ok": true, "accepted": 1}), batch.len())
        });
        assert_eq!(result["ok"], false);
        assert_eq!(result["accepted"], 1);
        assert_eq!(result["remaining"], 2);
        assert!(
            result["error"]
                .as_str()
                .unwrap()
                .starts_with("server_acked_local_commit_failed:")
        );
        fs::remove_dir(&path).unwrap();
        fs::rename(&saved, &path).unwrap();
        assert_eq!(configured(&path).pending_count(), 2);
        assert!(
            test_flush(&backend, |_, batch, _| accepted_batch_count(
                &json!({"ok": true, "accepted": 1}),
                batch.len()
            ))["ok"]
                .as_bool()
                .unwrap()
        );
        assert_eq!(configured(&path).pending_count(), 0);
    }

    fn session_event(id: &str, session: &str, context: &str) -> Value {
        let mut value = event(id, session, context);
        value["eventType"] = json!("session_end");
        value
    }

    fn heartbeat(backend: &EventBackend, foreground: bool, now_ms: i64, id: &str) {
        assert!(
            backend.lifecycle(
                foreground,
                now_ms,
                "2026-10-21T04:00:01.000Z",
                "2026-10-21T12:00:01.000+08:00",
                id
            ),
            "{}",
            backend.last_error()
        );
    }

    #[test]
    fn live_rotation_closes_the_old_session_and_commits_the_new_marker_atomically() {
        for platform in ["android", "ios"] {
            let path = temporary_path(&format!("rotate-{platform}"));
            let backend = EventBackend::new();
            assert!(backend.configure(
                path.to_str().unwrap(),
                "https://gamealgo.invalid/v1/events/batch",
                "ga_live_test",
                100,
                1000,
                platform,
            ));
            let mut old = session_event("old-end", "old-session", "");
            old["userId"] = json!("old-user");
            old["accountUserId"] = json!("old-account");
            old["isDebug"] = json!(true);
            assert!(backend.start_session(&old.to_string(), 1000));
            assert!(backend.bind_context("old-session", "old-context"));
            assert!(backend.enqueue(&event("gameplay", "old-session", "old-context").to_string()));
            // A Godot pause/resume need not be a true process-background edge.
            heartbeat(&backend, true, 1500, "unused");
            assert_eq!(backend.pending_count(), 1);
            let mut next = session_event("new-end", "new-session", "");
            next["timestamp"] = json!("2026-10-23T01:02:03.000Z");
            next["createdLocalAt"] = json!("2026-10-23T09:02:03.000+08:00");
            assert!(backend.start_session(&next.to_string(), 4000));
            let (queue, session) = load_state(&path).unwrap();
            assert_eq!(queue.len(), 2);
            assert_eq!(queue[0]["eventId"], "gameplay");
            assert_eq!(queue[1]["eventId"], "old-end");
            assert_eq!(queue[1]["sessionId"], "old-session");
            assert_eq!(queue[1]["contextId"], "old-context");
            assert_eq!(queue[1]["userId"], "old-user");
            assert_eq!(queue[1]["accountUserId"], "old-account");
            assert_eq!(queue[1]["isDebug"], true);
            assert_eq!(queue[1]["timestamp"], next["timestamp"]);
            assert_eq!(queue[1]["createdLocalAt"], next["createdLocalAt"]);
            assert_eq!(queue[1]["payload"]["reason"], "new_session");
            assert_eq!(queue[1]["payload"]["sessionDurationMs"], 500);
            assert_eq!(queue[1]["payload"]["recovered"], false);
            assert_eq!(queue[1]["payload"]["endTimeEstimated"], false);
            let session = session.unwrap();
            assert_eq!(session.event, next);
            assert_eq!(session.started_at_ms, 4000);
            assert!(session.open && !session.has_end);

            // Killing the process after the switch must not erase either end.
            let restored = configured(&path);
            assert!(restored.start_session(
                &session_event("third-end", "third-session", "").to_string(),
                9000,
            ));
            let queue: Vec<Value> = serde_json::from_str(&restored.snapshot_json()).unwrap();
            assert_eq!(
                queue.iter().filter(|e| e["eventId"] == "old-end").count(),
                1
            );
            assert_eq!(
                queue.iter().filter(|e| e["eventId"] == "new-end").count(),
                1
            );
            assert!(restored.clear());
        }
    }

    #[test]
    fn rotation_preserves_unbound_context_and_network_failure_does_not_undo_the_switch() {
        let path = temporary_path("rotate-offline");
        let backend = configured(&path);
        assert!(backend.start_session(&session_event("old-end", "old", "").to_string(), 1000));
        assert!(backend.start_session(&session_event("new-end", "new", "").to_string(), 2000));
        let blocked = test_flush(&backend, |_, _, _| panic!("unbound end must not be posted"));
        assert_eq!(blocked["error"], "context_not_ready");
        assert!(backend.bind_context("new", "new-context"));
        let queue: Vec<Value> = serde_json::from_str(&backend.snapshot_json()).unwrap();
        assert_eq!(queue[0]["contextId"], "");
        assert!(backend.bind_context("old", "old-context"));
        let failed = test_flush(&backend, |_, batch, _| {
            assert_eq!(batch[0]["sessionId"], "old");
            assert_eq!(batch[0]["contextId"], "old-context");
            Err("timeout".to_string())
        });
        assert_eq!(failed["ok"], false);
        assert_eq!(failed["remaining"], 1);
        let (queue, session) = load_state(&path).unwrap();
        assert_eq!(queue[0]["eventId"], "old-end");
        assert_eq!(session.unwrap().event["sessionId"], "new");
        let result = test_flush(&backend, |_, batch, _| {
            assert_eq!(batch[0]["eventId"], "old-end");
            Ok(batch.len())
        });
        assert_eq!(result["remaining"], 0);
        assert!(backend.clear());
    }

    #[test]
    fn rotation_after_background_ack_and_resume_does_not_extend_the_old_duration() {
        let path = temporary_path("rotate-after-ack");
        let backend = configured(&path);
        assert!(backend.start_session(
            &session_event("old-end", "old", "context").to_string(),
            1000
        ));
        let (job_id, generation) = reserve_test_flush(&backend);
        heartbeat(&backend, false, 2000, "unused");
        run_flush_with_post(
            Arc::clone(&backend.inner),
            job_id,
            generation,
            |_, batch, _| {
                assert_eq!(batch[0]["payload"]["sessionDurationMs"], 0);
                Ok(batch.len())
            },
        );
        assert_eq!(backend.pending_count(), 0);
        heartbeat(&backend, true, 3_600_000, "rearmed-end");
        assert!(backend.lock().unwrap().session.as_ref().unwrap().open);
        assert!(backend.start_session(&session_event("new-end", "new", "").to_string(), 3_601_000));
        let (queue, session) = load_state(&path).unwrap();
        assert!(queue.is_empty()); // no duplicate old end including the hour away
        assert_eq!(session.unwrap().event["sessionId"], "new");
        assert!(backend.clear());
    }

    #[test]
    fn rotation_after_a_manual_end_keeps_its_original_timestamp_and_duration() {
        let path = temporary_path("rotate-after-manual-end");
        let backend = configured(&path);
        assert!(backend.start_session(
            &session_event("native-end", "old", "context").to_string(),
            1000
        ));
        let mut manual = session_event("manual-end", "old", "context");
        manual["payload"] = json!({"sessionDurationMs": 500});
        assert!(backend.enqueue(&manual.to_string()));
        assert!(backend.start_session(&session_event("new-end", "new", "").to_string(), 9000));
        assert_eq!(load_state(&path).unwrap().0, vec![manual]);
        assert!(backend.clear());
    }

    #[test]
    fn live_rotation_commit_failure_preserves_the_old_session_for_a_single_retry() {
        let path = temporary_path("rotate-commit-failure");
        let backend = configured(&path);
        assert!(backend.start_session(
            &session_event("old-end", "old", "context").to_string(),
            1000
        ));
        assert!(backend.enqueue(&event("gameplay", "old", "context").to_string()));
        let durable_before = fs::read(&path).unwrap();
        let saved = path.with_extension("saved");
        fs::rename(&path, &saved).unwrap();
        fs::create_dir(&path).unwrap();
        let next = session_event("new-end", "new", "").to_string();
        assert!(!backend.start_session(&next, 2000));
        assert_eq!(backend.pending_count(), 1);
        {
            let inner = backend.lock().unwrap();
            let previous = inner.session.as_ref().unwrap();
            assert_eq!(previous.event["sessionId"], "old");
            assert!(previous.open && !previous.has_end);
            assert!(inner.active.is_none());
        }
        fs::remove_dir(&path).unwrap();
        fs::rename(&saved, &path).unwrap();
        assert_eq!(fs::read(&path).unwrap(), durable_before);
        assert!(backend.start_session(&next, 3000));
        let (queue, session) = load_state(&path).unwrap();
        assert_eq!(queue.len(), 2);
        assert_eq!(queue[1]["eventId"], "old-end");
        assert_eq!(queue[1]["payload"]["sessionDurationMs"], 0);
        assert_eq!(session.unwrap().event["sessionId"], "new");
        assert!(backend.clear());
    }

    #[test]
    fn rotation_during_upload_does_not_lose_the_old_end_when_the_batch_is_acked() {
        let path = temporary_path("rotate-inflight");
        let backend = configured(&path);
        assert!(backend.start_session(
            &session_event("old-end", "old", "context").to_string(),
            1000
        ));
        assert!(backend.enqueue(&event("gameplay", "old", "context").to_string()));
        let mut sent = Vec::new();
        let result = test_flush(&backend, |_, batch, _| {
            sent.push(batch[0]["eventId"].clone());
            if sent.len() == 1 {
                assert!(
                    backend.start_session(&session_event("new-end", "new", "").to_string(), 2000)
                );
            }
            Ok(batch.len())
        });
        assert_eq!(sent, vec![json!("gameplay"), json!("old-end")]);
        assert_eq!(result["remaining"], 0);
        assert_eq!(
            load_state(&path).unwrap().1.unwrap().event["sessionId"],
            "new"
        );
        assert!(backend.clear());
    }

    #[test]
    fn rotation_with_a_fully_inflight_queue_fails_without_overwriting_the_old_marker() {
        let path = temporary_path("rotate-full");
        let backend = configured(&path);
        backend.lock().unwrap().config.as_mut().unwrap().queue_limit = 1;
        assert!(backend.start_session(
            &session_event("old-end", "old", "context").to_string(),
            1000
        ));
        assert!(backend.enqueue(&event("gameplay", "old", "context").to_string()));
        let result = test_flush(&backend, |_, _, _| {
            let before = fs::read(&path).unwrap();
            assert!(!backend.start_session(&session_event("new-end", "new", "").to_string(), 2000));
            assert_eq!(backend.last_error(), "native_event_queue_full");
            assert_eq!(fs::read(&path).unwrap(), before);
            assert_eq!(
                backend.lock().unwrap().session.as_ref().unwrap().event["sessionId"],
                "old"
            );
            Err("timeout".to_string())
        });
        assert_eq!(result["remaining"], 1);
        assert!(backend.clear());
    }

    #[test]
    fn restarting_the_same_live_session_is_a_noop() {
        let path = temporary_path("rotate-same-id");
        let backend = configured(&path);
        assert!(backend.start_session(
            &session_event("old-end", "same", "context").to_string(),
            1000
        ));
        let before = fs::read(&path).unwrap();
        assert!(backend.start_session(&session_event("new-end", "same", "").to_string(), 9000));
        assert_eq!(fs::read(&path).unwrap(), before);
        assert_eq!(backend.pending_count(), 0);
        assert!(backend.clear());
    }

    #[test]
    fn pre_rotation_session_storage_remains_readable_for_recovery() {
        for open in [true, false] {
            let path = temporary_path("old-session-format");
            fs::write(
                &path,
                json!({
                    "version": 2, "events": [], "session": {
                        "event": session_event("old-end", "old", "context"),
                        "started_at_ms": 1000, "last_seen_ms": 2500, "open": open,
                    },
                })
                .to_string(),
            )
            .unwrap();
            let backend = configured(&path);
            assert!(backend.start_session(&session_event("new-end", "new", "").to_string(), 9000));
            assert_eq!(backend.pending_count(), i64::from(open));
            if open {
                let (queue, _) = load_state(&path).unwrap();
                assert_eq!(queue[0]["payload"]["sessionDurationMs"], 1500);
                assert_eq!(queue[0]["payload"]["reason"], "process_restart");
            }
            assert!(backend.clear());
        }
    }

    #[test]
    fn samples_recover_without_resume_and_only_checkpoints_are_durable() {
        let path = temporary_path("sampled-duration");
        let backend = configured(&path);
        assert!(backend.start_session(&session_event("end", "same", "ctx").to_string(), 1000));
        let initial = fs::read(&path).unwrap();
        backend.sample_duration(true, 2000);
        backend.sample_duration(true, 43_000);
        assert_eq!(backend.duration_ms(), 2000); // never catch up a delayed callback
        assert_eq!(fs::read(&path).unwrap(), initial); // no per-second writes
        heartbeat(&backend, false, 43_000, "unused");
        backend.sample_duration(false, 100_000);
        assert_eq!(backend.duration_ms(), 2000); // background handlers may still execute
        backend.sample_duration(true, 200_000); // omit the resume notification
        backend.sample_duration(true, 201_000);
        assert_eq!(backend.duration_ms(), 3000);
        heartbeat(&backend, true, 201_000, "rearmed-end");
        backend.sample_duration(true, 202_000);
        assert_eq!(backend.duration_ms(), 4000);
        let restored = configured(&path);
        assert!(restored.start_session(
            &session_event("new-end", "next", "ctx").to_string(),
            900_000
        ));
        let queue: Vec<Value> = serde_json::from_str(&restored.snapshot_json()).unwrap();
        let recovered = queue
            .iter()
            .find(|e| e["payload"]["reason"] == "process_restart")
            .unwrap();
        assert_eq!(recovered["payload"]["sessionDurationMs"], 3000);
        assert!(backend.start_session(
            &session_event("ignored", "same", "ctx2").to_string(),
            999_000
        ));
        assert_eq!(backend.duration_ms(), 4000); // same-ID metadata does not reset timing
        assert!(backend.start_session(
            &session_event("new-end", "next", "ctx").to_string(),
            999_000
        ));
        assert_eq!(backend.duration_ms(), 0);
        assert!(backend.clear());
    }

    #[test]
    fn event_writes_between_heartbeats_save_matching_duration_and_observation_time() {
        let path = temporary_path("sample-event-persist");
        let backend = configured(&path);
        assert!(backend.start_session(&session_event("end", "old", "ctx").to_string(), 1000));
        backend.sample_duration_at(
            true,
            2000,
            "2026-10-30T00:00:02.000Z",
            "2026-10-30T08:00:02.000+08:00",
        );
        assert!(backend.enqueue(&event("ordinary", "old", "ctx").to_string()));
        let restored = configured(&path);
        assert!(
            restored.start_session(&session_event("new-end", "new", "ctx").to_string(), 900_000)
        );
        let queue: Vec<Value> = serde_json::from_str(&restored.snapshot_json()).unwrap();
        assert_eq!(queue[1]["payload"]["sessionDurationMs"], 1000);
        assert_eq!(queue[1]["timestamp"], "2026-10-30T00:00:02.000Z");
        assert!(restored.clear());
    }

    #[test]
    fn killed_session_recovers_original_identity_context_and_last_seen_time() {
        let path = temporary_path("killed-session");
        let backend = configured(&path);
        assert!(backend.start_session(
            &session_event("old-end", "old-session", "").to_string(),
            1000
        ));
        assert!(backend.bind_context("old-session", "old-context"));
        heartbeat(&backend, true, 3500, "unused");
        let restored = configured(&path);
        // Loading while consent is unresolved does not generate or upload data.
        heartbeat(&restored, false, 20_000, "unused");
        assert_eq!(restored.pending_count(), 0);
        assert!(restored.lock().unwrap().active.is_none());
        assert!(restored.start_session(
            &session_event("new-end", "new-session", "").to_string(),
            50_000
        ));
        let queue: Vec<Value> = serde_json::from_str(&restored.snapshot_json()).unwrap();
        assert_eq!(queue.len(), 1);
        assert_eq!(queue[0]["eventId"], "old-end");
        assert_eq!(queue[0]["sessionId"], "old-session");
        assert_eq!(queue[0]["contextId"], "old-context");
        assert_eq!(queue[0]["payload"]["sessionDurationMs"], 1000);
        assert_eq!(queue[0]["payload"]["reason"], "process_restart");
        assert_eq!(queue[0]["payload"]["endTimeEstimated"], true);
        assert_eq!(queue[0]["timestamp"], "2026-10-21T04:00:01.000Z");
        let again = configured(&path);
        assert!(again.start_session(
            &session_event("next-end", "next-session", "").to_string(),
            100_000
        ));
        let queue: Vec<Value> = serde_json::from_str(&again.snapshot_json()).unwrap();
        assert_eq!(
            queue.iter().filter(|e| e["eventId"] == "old-end").count(),
            1
        );
        assert!(again.clear());
    }

    #[test]
    fn every_background_reports_but_closed_sessions_do_not_recover_after_ack() {
        let path = temporary_path("background");
        let backend = configured(&path);
        assert!(backend.start_session(&session_event("end-1", "session", "").to_string(), 1000));
        // The app may already have reported; the process transition is allowed
        // to produce its own end, without a global sessionId deduplication rule.
        assert!(backend.enqueue(&session_event("app-end", "session", "").to_string()));
        heartbeat(&backend, false, 2000, "unused");
        heartbeat(&backend, true, 3000, "end-2");
        heartbeat(&backend, false, 4000, "unused");
        let queue: Vec<Value> = serde_json::from_str(&backend.snapshot_json()).unwrap();
        assert_eq!(queue.len(), 3);
        assert_eq!(queue[1]["eventId"], "end-1");
        assert_eq!(queue[2]["eventId"], "end-2");
        assert_eq!(queue[2]["payload"]["sessionDurationMs"], 0);
        // Simulate the same atomic removal that the upload worker performs.
        {
            let inner = backend.lock().unwrap();
            persist_state(&path, &[], inner.session.as_ref()).unwrap();
        }
        let restored = configured(&path);
        assert!(restored.start_session(
            &session_event("new-end", "new-session", "").to_string(),
            5000
        ));
        assert_eq!(restored.pending_count(), 0);
        assert!(restored.clear());
    }

    #[test]
    fn consent_clear_removes_session_recovery_and_disables_lifecycle_uploads() {
        let path = temporary_path("session-consent");
        let backend = configured(&path);
        assert!(backend.start_session(
            &session_event("end", "session", "context").to_string(),
            1000
        ));
        assert!(backend.clear());
        heartbeat(&backend, false, 2000, "unused");
        assert!(!path.exists());
        assert!(backend.lock().unwrap().active.is_none());
        let restored = configured(&path);
        assert!(restored.start_session(
            &session_event("new-end", "new-session", "").to_string(),
            3000
        ));
        assert_eq!(restored.pending_count(), 0);
        assert!(restored.clear());
    }

    #[test]
    fn session_recovery_commit_failure_retains_original_end_id_for_retry() {
        let path = temporary_path("session-commit");
        let backend = configured(&path);
        assert!(backend.start_session(
            &session_event("old-end", "old-session", "").to_string(),
            1000
        ));
        let restored = configured(&path);
        let saved = path.with_extension("saved");
        fs::rename(&path, &saved).unwrap();
        fs::create_dir(&path).unwrap(); // Force the final atomic rename to fail.
        let new_event = session_event("new-end", "new-session", "").to_string();
        assert!(!restored.start_session(&new_event, 2000));
        assert_eq!(restored.pending_count(), 0);
        fs::remove_dir(&path).unwrap();
        fs::rename(&saved, &path).unwrap();
        assert!(restored.start_session(&new_event, 2000));
        let queue: Vec<Value> = serde_json::from_str(&restored.snapshot_json()).unwrap();
        assert_eq!(queue.len(), 1);
        assert_eq!(queue[0]["eventId"], "old-end");
        assert!(restored.clear());
    }

    #[test]
    fn ios_background_persistence_failure_retries_without_losing_the_end() {
        let path = temporary_path("ios-background-retry");
        let backend = EventBackend::new();
        assert!(backend.configure(
            path.to_str().unwrap(),
            "https://gamealgo.invalid/v1/events/batch",
            "ga_live_test",
            100,
            1000,
            "ios"
        ));
        assert!(backend.start_session(
            &session_event("ios-end", "ios-session", "ios-context").to_string(),
            1000
        ));
        heartbeat(&backend, true, 1500, "unused");
        assert_eq!(backend.pending_count(), 0); // foreground/ad heartbeat
        let saved = path.with_extension("saved");
        fs::rename(&path, &saved).unwrap();
        fs::create_dir(&path).unwrap();
        assert!(!backend.lifecycle(false, 2000, "utc", "local", "unused"));
        assert_eq!(backend.pending_count(), 0);
        assert!(backend.lock().unwrap().foreground);
        assert!(backend.lock().unwrap().session.as_ref().unwrap().open);
        fs::remove_dir(&path).unwrap();
        fs::rename(&saved, &path).unwrap();
        heartbeat(&backend, false, 2100, "unused");
        heartbeat(&backend, false, 2200, "unused"); // duplicate notification
        let queue: Vec<Value> = serde_json::from_str(&backend.snapshot_json()).unwrap();
        assert_eq!(queue.len(), 1);
        assert_eq!(queue[0]["eventId"], "ios-end");
        assert_eq!(queue[0]["payload"]["reason"], "background");
        assert_eq!(queue[0]["payload"]["endTimeEstimated"], false);
        assert_eq!(queue[0]["payload"]["sessionDurationMs"], 500);
        assert!(!backend.lock().unwrap().session.as_ref().unwrap().open);
        assert!(backend.clear());
    }

    #[test]
    fn legacy_array_queue_migrates_without_changing_event_ids() {
        let path = temporary_path("legacy");
        fs::write(
            &path,
            json!([event("legacy-event", "old", "context")]).to_string(),
        )
        .unwrap();
        let backend = configured(&path);
        assert!(backend.start_session(&session_event("end", "session", "").to_string(), 1000));
        let (events, session) = load_state(&path).unwrap();
        assert_eq!(events[0]["eventId"], "legacy-event");
        assert!(session.unwrap().open);
        assert!(backend.clear());
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
