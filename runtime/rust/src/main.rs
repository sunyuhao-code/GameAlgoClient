use gamealgo_script_runtime::{ExecuteResponse, PreparedScript, RuntimeLimits};
use serde::Deserialize;
use serde_json::Value;
use std::collections::{HashMap, VecDeque};
use std::io::{self, BufRead, Write};

const MAX_CACHED_SCRIPTS: usize = 4;

#[derive(Deserialize)]
struct RuntimeRequest {
    #[serde(default)]
    op: Option<String>,
    script: String,
    #[serde(default)]
    input: Option<Value>,
}

struct ScriptCache {
    scripts: HashMap<String, PreparedScript>,
    lru: VecDeque<String>,
}

impl ScriptCache {
    fn new() -> Self {
        Self {
            scripts: HashMap::new(),
            lru: VecDeque::new(),
        }
    }

    fn touch(&mut self, script: &str) {
        self.lru.retain(|key| key != script);
        self.lru.push_back(script.to_string());
    }

    fn prepare(&mut self, script: &str) -> Result<(), String> {
        if self.scripts.contains_key(script) {
            self.touch(script);
            return Ok(());
        }
        let prepared = PreparedScript::prepare(script, &RuntimeLimits::default())
            .map_err(|error| error.to_string())?;
        if self.scripts.len() >= MAX_CACHED_SCRIPTS {
            if let Some(oldest) = self.lru.pop_front() {
                self.scripts.remove(&oldest);
            }
        }
        self.scripts.insert(script.to_string(), prepared);
        self.touch(script);
        Ok(())
    }

    fn execute(&mut self, script: &str, input: &Value) -> ExecuteResponse {
        if let Err(message) = self.prepare(script) {
            return ExecuteResponse::Error { message };
        }
        let prepared = self.scripts.get(script).expect("prepared script inserted");
        match prepared.execute(input) {
            Ok(result) => ExecuteResponse::Ok { result },
            Err(error) => ExecuteResponse::Error {
                message: error.to_string(),
            },
        }
    }
}

fn process_request(cache: &mut ScriptCache, request: RuntimeRequest) -> serde_json::Value {
    match request.op.as_deref() {
        Some("prepare") => match cache.prepare(&request.script) {
            Ok(()) => serde_json::json!({"status":"ok","prepared":true}),
            Err(message) => serde_json::json!({"status":"error","message":message}),
        },
        None | Some("execute") => {
            let Some(input) = request.input else {
                return serde_json::json!({"status":"error","message":"input is required"});
            };
            serde_json::to_value(cache.execute(&request.script, &input))
                .expect("runtime response JSON")
        }
        Some(op) => serde_json::json!({
            "status":"error",
            "message":format!("unsupported runtime operation: {op}")
        }),
    }
}

fn main() {
    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    let mut cache = ScriptCache::new();
    for line in stdin.lock().lines() {
        let response = match line {
            Ok(line) if line.trim().is_empty() => continue,
            Ok(line) => match serde_json::from_str::<RuntimeRequest>(&line) {
                Ok(request) => process_request(&mut cache, request),
                Err(error) => serde_json::json!({
                    "status":"error",
                    "message":format!("invalid request: {error}")
                }),
            },
            Err(error) => serde_json::json!({
                "status":"error",
                "message":format!("failed to read runtime request: {error}")
            }),
        };
        let encoded = serde_json::to_vec(&response).expect("response JSON");
        if stdout.write_all(&encoded).is_err() || stdout.write_all(b"\n").is_err() {
            break;
        }
        if stdout.flush().is_err() {
            break;
        }
    }
}
