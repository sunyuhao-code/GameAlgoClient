use rquickjs::{Context, Function, Runtime};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::ffi::{CStr, CString, c_char};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicU64, Ordering},
};
use std::time::{Duration, Instant};
use thiserror::Error;

pub const DEFAULT_INPUT_LIMIT_BYTES: usize = 256 * 1024;
pub const DEFAULT_OUTPUT_LIMIT_BYTES: usize = 256 * 1024;
pub const DEFAULT_SCRIPT_LIMIT_BYTES: usize = 10 * 1024 * 1024;
pub const DEFAULT_MEMORY_LIMIT_BYTES: usize = 64 * 1024 * 1024;
pub const DEFAULT_STACK_LIMIT_BYTES: usize = 512 * 1024;
pub const DEFAULT_INTERRUPT_POLL_LIMIT: u64 = 100_000;
pub const DEFAULT_EXECUTION_TIMEOUT: Duration = Duration::from_secs(1);
pub const DEFAULT_PREPARE_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, Error)]
pub enum RuntimeError {
    #[error("script exceeds {0} bytes")]
    ScriptTooLarge(usize),
    #[error("input exceeds {0} bytes")]
    InputTooLarge(usize),
    #[error("input is not valid JSON: {0}")]
    InvalidInput(serde_json::Error),
    #[error("script execution failed: {0}")]
    Execution(String),
    #[error("script execution exceeded its resource limit")]
    ResourceLimit,
    #[error("script returned an unsupported value")]
    UnsupportedOutput,
    #[error("output exceeds {0} bytes")]
    OutputTooLarge(usize),
    #[error("runtime received invalid UTF-8")]
    InvalidUtf8,
}

#[derive(Clone, Debug)]
pub struct RuntimeLimits {
    pub input_bytes: usize,
    pub output_bytes: usize,
    pub script_bytes: usize,
    pub memory_bytes: usize,
    pub stack_bytes: usize,
    pub interrupt_polls: u64,
    pub execution_timeout: Duration,
    pub prepare_timeout: Duration,
}

impl Default for RuntimeLimits {
    fn default() -> Self {
        Self {
            input_bytes: DEFAULT_INPUT_LIMIT_BYTES,
            output_bytes: DEFAULT_OUTPUT_LIMIT_BYTES,
            script_bytes: DEFAULT_SCRIPT_LIMIT_BYTES,
            memory_bytes: DEFAULT_MEMORY_LIMIT_BYTES,
            stack_bytes: DEFAULT_STACK_LIMIT_BYTES,
            interrupt_polls: DEFAULT_INTERRUPT_POLL_LIMIT,
            execution_timeout: DEFAULT_EXECUTION_TIMEOUT,
            prepare_timeout: DEFAULT_PREPARE_TIMEOUT,
        }
    }
}

const PRELUDE: &str = r#"
    const __gamealgoDisableConstructor = (value) => {
      const prototype = Object.getPrototypeOf(value);
      if (prototype && Object.prototype.hasOwnProperty.call(prototype, "constructor")) {
        Object.defineProperty(prototype, "constructor", {
          value: undefined,
          writable: false,
          configurable: false
        });
      }
    };
    __gamealgoDisableConstructor(function() {});
    __gamealgoDisableConstructor(async function() {});
    __gamealgoDisableConstructor(function*() {});
    __gamealgoDisableConstructor(async function*() {});
    delete globalThis.eval;
    delete globalThis.Function;
    delete globalThis.AsyncFunction;
    delete globalThis.GeneratorFunction;
    delete globalThis.AsyncGeneratorFunction;
    delete globalThis.WebAssembly;
    delete globalThis.Date;
    Object.defineProperty(Math, "random", { value: undefined, writable: false, configurable: false });
    Object.defineProperty(globalThis, "__gamealgoDeepFreeze", {
      value: (value, seen = new Set()) => {
        if (value === null || typeof value !== "object" || seen.has(value)) return value;
        seen.add(value);
        for (const key of Object.keys(value)) __gamealgoDeepFreeze(value[key], seen);
        return Object.freeze(value);
      },
      writable: false,
      configurable: false
    });
"#;

fn install_interrupt_handler(
    runtime: &Runtime,
    limits: &RuntimeLimits,
    timeout: Duration,
) -> Arc<AtomicBool> {
    let interrupted = Arc::new(AtomicBool::new(false));
    let interrupted_by_handler = Arc::clone(&interrupted);
    let polls = Arc::new(AtomicU64::new(0));
    let polls_by_handler = Arc::clone(&polls);
    let deadline = Instant::now() + timeout;
    let poll_limit = limits.interrupt_polls;
    runtime.set_interrupt_handler(Some(Box::new(move || {
        let over_limit = polls_by_handler.fetch_add(1, Ordering::Relaxed) >= poll_limit
            || Instant::now() >= deadline;
        if over_limit {
            interrupted_by_handler.store(true, Ordering::Relaxed);
        }
        over_limit
    })));
    interrupted
}

pub struct PreparedScript {
    runtime: Runtime,
    context: Context,
    limits: RuntimeLimits,
}

impl PreparedScript {
    pub fn prepare(script: &str, limits: &RuntimeLimits) -> Result<Self, RuntimeError> {
        if script.len() > limits.script_bytes {
            return Err(RuntimeError::ScriptTooLarge(limits.script_bytes));
        }

        let runtime = Runtime::new().map_err(|error| RuntimeError::Execution(error.to_string()))?;
        runtime.set_memory_limit(limits.memory_bytes);
        runtime.set_max_stack_size(limits.stack_bytes);

        let interrupted = install_interrupt_handler(&runtime, limits, limits.prepare_timeout);
        let context =
            Context::full(&runtime).map_err(|error| RuntimeError::Execution(error.to_string()))?;

        let source = format!(
            "{PRELUDE}\n{script}\n;if (typeof execute !== 'function') throw new Error('script must define execute(input)');"
        );
        let prepared = context.with(|ctx| ctx.eval::<(), _>(source));
        runtime.set_interrupt_handler(None);
        prepared.map_err(|error| {
            if interrupted.load(Ordering::Relaxed) {
                RuntimeError::ResourceLimit
            } else {
                RuntimeError::Execution(error.to_string())
            }
        })?;

        Ok(Self {
            runtime,
            context,
            limits: limits.clone(),
        })
    }

    pub fn execute(&self, input: &Value) -> Result<Value, RuntimeError> {
        let input_json = serde_json::to_string(input).map_err(RuntimeError::InvalidInput)?;
        if input_json.len() > self.limits.input_bytes {
            return Err(RuntimeError::InputTooLarge(self.limits.input_bytes));
        }

        let interrupted =
            install_interrupt_handler(&self.runtime, &self.limits, self.limits.execution_timeout);
        let result = self.context.with(|ctx| -> Result<String, RuntimeError> {
            let input_value = ctx
                .json_parse(input_json)
                .map_err(|error| RuntimeError::Execution(error.to_string()))?;
            let freeze: Function = ctx
                .globals()
                .get("__gamealgoDeepFreeze")
                .map_err(|error| RuntimeError::Execution(error.to_string()))?;
            let input_value: rquickjs::Value = freeze
                .call((input_value,))
                .map_err(|error| RuntimeError::Execution(error.to_string()))?;
            let execute: Function = ctx
                .eval("execute")
                .map_err(|error| RuntimeError::Execution(error.to_string()))?;
            let output: rquickjs::Value = execute
                .call((input_value,))
                .map_err(|error| RuntimeError::Execution(error.to_string()))?;
            let encoded = ctx
                .json_stringify(output)
                .map_err(|error| RuntimeError::Execution(error.to_string()))?
                .ok_or(RuntimeError::UnsupportedOutput)?;
            encoded
                .to_string()
                .map_err(|error| RuntimeError::Execution(error.to_string()))
        });
        self.runtime.set_interrupt_handler(None);
        let encoded = result.map_err(|error| {
            if interrupted.load(Ordering::Relaxed) {
                RuntimeError::ResourceLimit
            } else {
                error
            }
        })?;
        if encoded.len() > self.limits.output_bytes {
            return Err(RuntimeError::OutputTooLarge(self.limits.output_bytes));
        }
        serde_json::from_str(&encoded).map_err(|_| RuntimeError::UnsupportedOutput)
    }
}

pub fn execute(script: &str, input: &Value, limits: &RuntimeLimits) -> Result<Value, RuntimeError> {
    PreparedScript::prepare(script, limits)?.execute(input)
}

#[derive(Deserialize)]
pub struct ExecuteRequest {
    pub script: String,
    pub input: Value,
}

#[derive(Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ExecuteResponse {
    Ok { result: Value },
    Error { message: String },
}

#[derive(Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum PrepareResponse {
    Ok { handle: u64 },
    Error { message: String },
}

pub struct GameAlgoRuntimeHandle {
    prepared: Mutex<PreparedScript>,
}

fn prepare_response(script: &str) -> PrepareResponse {
    match PreparedScript::prepare(script, &RuntimeLimits::default()) {
        Ok(prepared) => {
            let handle = Box::into_raw(Box::new(GameAlgoRuntimeHandle {
                prepared: Mutex::new(prepared),
            })) as u64;
            PrepareResponse::Ok { handle }
        }
        Err(error) => PrepareResponse::Error {
            message: error.to_string(),
        },
    }
}

fn execute_prepared_response(
    handle: *mut GameAlgoRuntimeHandle,
    input_json: &str,
) -> ExecuteResponse {
    if handle.is_null() {
        return ExecuteResponse::Error {
            message: "runtime handle is null".to_string(),
        };
    }
    let input = match serde_json::from_str::<Value>(input_json) {
        Ok(input) => input,
        Err(error) => {
            return ExecuteResponse::Error {
                message: format!("invalid input: {error}"),
            };
        }
    };
    let handle = unsafe { &*handle };
    let prepared = match handle.prepared.lock() {
        Ok(prepared) => prepared,
        Err(_) => {
            return ExecuteResponse::Error {
                message: "runtime handle is poisoned".to_string(),
            };
        }
    };
    match prepared.execute(&input) {
        Ok(result) => ExecuteResponse::Ok { result },
        Err(error) => ExecuteResponse::Error {
            message: error.to_string(),
        },
    }
}

fn encode_json<T: Serialize>(value: &T) -> *mut c_char {
    let encoded = serde_json::to_string(value).unwrap_or_else(|_| {
        r#"{"status":"error","message":"failed to encode runtime response"}"#.to_string()
    });
    CString::new(encoded)
        .expect("JSON cannot contain NUL")
        .into_raw()
}

pub fn execute_request(request: ExecuteRequest) -> ExecuteResponse {
    match execute(&request.script, &request.input, &RuntimeLimits::default()) {
        Ok(result) => ExecuteResponse::Ok { result },
        Err(error) => ExecuteResponse::Error {
            message: error.to_string(),
        },
    }
}

/// Prepares a script once and returns an opaque handle for subsequent calls.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gamealgo_runtime_prepare(script: *const c_char) -> *mut c_char {
    let response = if script.is_null() {
        PrepareResponse::Error {
            message: "script is null".to_string(),
        }
    } else {
        let script = unsafe { CStr::from_ptr(script) };
        match script.to_str() {
            Ok(script) => prepare_response(script),
            Err(_) => PrepareResponse::Error {
                message: RuntimeError::InvalidUtf8.to_string(),
            },
        }
    };
    encode_json(&response)
}

/// Executes a prepared script against one JSON input.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gamealgo_runtime_execute_prepared(
    handle: *mut GameAlgoRuntimeHandle,
    input_json: *const c_char,
) -> *mut c_char {
    let response = if input_json.is_null() {
        ExecuteResponse::Error {
            message: "input is null".to_string(),
        }
    } else {
        let input_json = unsafe { CStr::from_ptr(input_json) };
        match input_json.to_str() {
            Ok(input_json) => execute_prepared_response(handle, input_json),
            Err(_) => ExecuteResponse::Error {
                message: RuntimeError::InvalidUtf8.to_string(),
            },
        }
    };
    encode_json(&response)
}

/// Releases a prepared script handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gamealgo_runtime_release(handle: *mut GameAlgoRuntimeHandle) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// C ABI used by the Swift and Android native adapters. The returned UTF-8
/// JSON string must be released with `gamealgo_runtime_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gamealgo_runtime_execute(request_json: *const c_char) -> *mut c_char {
    let response = if request_json.is_null() {
        ExecuteResponse::Error {
            message: "request is null".to_string(),
        }
    } else {
        // SAFETY: callers pass a NUL-terminated string for the duration of this call.
        let request = unsafe { CStr::from_ptr(request_json) };
        match request.to_str() {
            Ok(value) => match serde_json::from_str::<ExecuteRequest>(value) {
                Ok(request) => execute_request(request),
                Err(error) => ExecuteResponse::Error {
                    message: format!("invalid request: {error}"),
                },
            },
            Err(_) => ExecuteResponse::Error {
                message: RuntimeError::InvalidUtf8.to_string(),
            },
        }
    };
    encode_json(&response)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gamealgo_runtime_free(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: value was allocated by CString::into_raw above and is freed once.
        drop(unsafe { CString::from_raw(value) });
    }
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_gamealgo_sdk_RustGameAlgoScriptRuntime_nativeExecute<'local>(
    mut env: jni::JNIEnv<'local>,
    _class: jni::objects::JClass<'local>,
    request: jni::objects::JString<'local>,
) -> jni::sys::jstring {
    let request: String = match env.get_string(&request) {
        Ok(value) => value.into(),
        Err(error) => {
            let response = ExecuteResponse::Error {
                message: format!("invalid UTF-8 request: {error}"),
            };
            return java_response(&env, &response);
        }
    };
    let response = match serde_json::from_str::<ExecuteRequest>(&request) {
        Ok(request) => execute_request(request),
        Err(error) => ExecuteResponse::Error {
            message: format!("invalid request: {error}"),
        },
    };
    java_response(&env, &response)
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_gamealgo_sdk_RustGameAlgoScriptRuntime_nativePrepare<'local>(
    mut env: jni::JNIEnv<'local>,
    _class: jni::objects::JClass<'local>,
    script: jni::objects::JString<'local>,
) -> jni::sys::jstring {
    let script: String = match env.get_string(&script) {
        Ok(value) => value.into(),
        Err(error) => {
            return java_string(
                &env,
                &serde_json::json!({"status":"error","message":error.to_string()}),
            );
        }
    };
    java_string(
        &env,
        &serde_json::to_value(prepare_response(&script)).unwrap(),
    )
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_gamealgo_sdk_RustGameAlgoScriptRuntime_nativeExecutePrepared<
    'local,
>(
    mut env: jni::JNIEnv<'local>,
    _class: jni::objects::JClass<'local>,
    handle: jni::sys::jlong,
    input: jni::objects::JString<'local>,
) -> jni::sys::jstring {
    let input: String = match env.get_string(&input) {
        Ok(value) => value.into(),
        Err(error) => {
            return java_string(
                &env,
                &serde_json::json!({"status":"error","message":error.to_string()}),
            );
        }
    };
    let response = execute_prepared_response(handle as *mut GameAlgoRuntimeHandle, &input);
    java_string(&env, &serde_json::to_value(response).unwrap())
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_gamealgo_sdk_RustGameAlgoScriptRuntime_nativeRelease(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
) {
    unsafe { gamealgo_runtime_release(handle as *mut GameAlgoRuntimeHandle) };
}

#[cfg(target_os = "android")]
fn java_response(env: &jni::JNIEnv<'_>, response: &ExecuteResponse) -> jni::sys::jstring {
    let encoded = serde_json::to_string(response).unwrap_or_else(|_| {
        r#"{"status":"error","message":"failed to encode runtime response"}"#.to_string()
    });
    env.new_string(encoded)
        .map(|value| value.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[cfg(target_os = "android")]
fn java_string(env: &jni::JNIEnv<'_>, value: &serde_json::Value) -> jni::sys::jstring {
    let encoded = serde_json::to_string(value).unwrap_or_else(|_| {
        r#"{"status":"error","message":"failed to encode runtime response"}"#.to_string()
    });
    env.new_string(encoded)
        .map(|value| value.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const FIXTURE_SCRIPT: &str = include_str!("../../../protocol/fixtures/script-fixture.js");

    #[test]
    fn executes_shared_fixture_deterministically() {
        let input = json!({"config":{"level":2},"state":{},"meta":{}});
        let first = execute(FIXTURE_SCRIPT, &input, &RuntimeLimits::default()).unwrap();
        let second = execute(FIXTURE_SCRIPT, &input, &RuntimeLimits::default()).unwrap();
        assert_eq!(
            first,
            json!({"payload":{"level":2},"diagnostics":{"fixture":true}})
        );
        assert_eq!(first, second);
    }

    #[test]
    fn exposes_no_host_or_dynamic_code_capabilities() {
        let script = r#"function execute() { return { payload: {
          process: typeof process,
          require: typeof require,
          fetch: typeof fetch,
          eval: typeof eval,
          Function: typeof Function,
          Date: typeof Date,
          random: typeof Math.random
        }}; }"#;
        let result = execute(script, &json!({}), &RuntimeLimits::default()).unwrap();
        assert_eq!(
            result["payload"],
            json!({
                "process":"undefined", "require":"undefined", "fetch":"undefined",
                "eval":"undefined", "Function":"undefined", "Date":"undefined", "random":"undefined"
            })
        );
    }

    #[test]
    fn blocks_indirect_function_constructors() {
        for constructor in [
            "(function() {}).constructor",
            "Object.constructor",
            "(async function() {}).constructor",
            "(function*() {}).constructor",
            "(async function*() {}).constructor",
        ] {
            let script = format!(
                "function execute() {{ const constructor = {constructor}; return {{ payload: typeof constructor }}; }}"
            );
            let result = execute(&script, &json!({}), &RuntimeLimits::default()).unwrap();
            assert_eq!(result["payload"], json!("undefined"), "{constructor}");
        }

        let error = execute(
            "function execute() { return { payload: (function() {}).constructor('return 7')() }; }",
            &json!({}),
            &RuntimeLimits::default(),
        )
        .unwrap_err();
        assert!(matches!(error, RuntimeError::Execution(_)));
    }

    #[test]
    fn interrupts_unbounded_loops() {
        let error = execute(
            "function execute() { while (true) {} }",
            &json!({}),
            &RuntimeLimits {
                interrupt_polls: 1,
                execution_timeout: Duration::from_millis(5),
                ..RuntimeLimits::default()
            },
        )
        .unwrap_err();
        assert!(matches!(error, RuntimeError::ResourceLimit));
    }

    #[test]
    fn prepared_script_reuses_top_level_constants_without_mutable_state() {
        let script = r#"
            const levels = Object.freeze(["easy", "hard"]);
            function execute(input) {
                return { payload: { level: levels[input.index] || levels[0] } };
            }
        "#;
        let prepared = PreparedScript::prepare(script, &RuntimeLimits::default()).unwrap();
        assert_eq!(
            prepared.execute(&json!({"index": 1})).unwrap(),
            json!({"payload":{"level":"hard"}})
        );
        assert_eq!(
            prepared.execute(&json!({"index": 99})).unwrap(),
            json!({"payload":{"level":"easy"}})
        );
    }

    #[test]
    fn accepts_script_near_ten_megabytes() {
        let prefix = "function execute(input) { return { payload: input }; }\n";
        let filler_len = DEFAULT_SCRIPT_LIMIT_BYTES - prefix.len();
        let script = format!("{prefix}//{}", "x".repeat(filler_len.saturating_sub(3)));
        assert!(script.len() <= DEFAULT_SCRIPT_LIMIT_BYTES);
        let prepared = PreparedScript::prepare(&script, &RuntimeLimits::default()).unwrap();
        assert_eq!(
            prepared.execute(&json!({"ok": true})).unwrap(),
            json!({"payload": {"ok": true}})
        );
    }

    #[test]
    fn rejects_script_over_ten_megabytes() {
        let script = "x".repeat(DEFAULT_SCRIPT_LIMIT_BYTES + 1);
        let error = match PreparedScript::prepare(&script, &RuntimeLimits::default()) {
            Ok(_) => panic!("oversized script unexpectedly prepared"),
            Err(error) => error,
        };
        assert!(matches!(
            error,
            RuntimeError::ScriptTooLarge(DEFAULT_SCRIPT_LIMIT_BYTES)
        ));
    }
}
