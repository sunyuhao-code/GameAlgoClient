use rquickjs::{Context, Runtime};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::ffi::{CStr, CString, c_char};
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, Ordering},
};
use std::time::{Duration, Instant};
use thiserror::Error;

pub const DEFAULT_INPUT_LIMIT_BYTES: usize = 256 * 1024;
pub const DEFAULT_OUTPUT_LIMIT_BYTES: usize = 256 * 1024;
pub const DEFAULT_SCRIPT_LIMIT_BYTES: usize = 512 * 1024;
pub const DEFAULT_MEMORY_LIMIT_BYTES: usize = 16 * 1024 * 1024;
pub const DEFAULT_STACK_LIMIT_BYTES: usize = 512 * 1024;
pub const DEFAULT_INTERRUPT_POLL_LIMIT: u64 = 100_000;
pub const DEFAULT_EXECUTION_TIMEOUT: Duration = Duration::from_millis(50);

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
        }
    }
}

pub fn execute(script: &str, input: &Value, limits: &RuntimeLimits) -> Result<Value, RuntimeError> {
    if script.len() > limits.script_bytes {
        return Err(RuntimeError::ScriptTooLarge(limits.script_bytes));
    }
    let input_json = serde_json::to_string(input).map_err(RuntimeError::InvalidInput)?;
    if input_json.len() > limits.input_bytes {
        return Err(RuntimeError::InputTooLarge(limits.input_bytes));
    }

    let runtime = Runtime::new().map_err(|error| RuntimeError::Execution(error.to_string()))?;
    runtime.set_memory_limit(limits.memory_bytes);
    runtime.set_max_stack_size(limits.stack_bytes);

    let interrupted = Arc::new(AtomicBool::new(false));
    let interrupted_by_handler = Arc::clone(&interrupted);
    let polls = Arc::new(AtomicU64::new(0));
    let polls_by_handler = Arc::clone(&polls);
    let deadline = Instant::now() + limits.execution_timeout;
    let poll_limit = limits.interrupt_polls;
    runtime.set_interrupt_handler(Some(Box::new(move || {
        let over_limit = polls_by_handler.fetch_add(1, Ordering::Relaxed) >= poll_limit
            || Instant::now() >= deadline;
        if over_limit {
            interrupted_by_handler.store(true, Ordering::Relaxed);
        }
        over_limit
    })));
    let context =
        Context::full(&runtime).map_err(|error| RuntimeError::Execution(error.to_string()))?;

    // QuickJS starts without Node/browser host APIs. The prelude also removes
    // dynamic code and nondeterministic built-ins so a strategy can only
    // transform its JSON input into JSON output.
    let prelude = r#"
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
        const __gamealgoDeepFreeze = (value, seen = new Set()) => {
          if (value === null || typeof value !== "object" || seen.has(value)) return value;
          seen.add(value);
          for (const key of Object.keys(value)) __gamealgoDeepFreeze(value[key], seen);
          return Object.freeze(value);
        };
    "#;
    let source = format!(
        "{prelude}\n{script}\n;if (typeof execute !== 'function') throw new Error('script must define execute(input)');\nJSON.stringify(execute(__gamealgoDeepFreeze({input_json})))"
    );
    let encoded = context
        .with(|ctx| ctx.eval::<String, _>(source))
        .map_err(|error| {
            if interrupted.load(Ordering::Relaxed) {
                RuntimeError::ResourceLimit
            } else {
                RuntimeError::Execution(error.to_string())
            }
        })?;
    if encoded.len() > limits.output_bytes {
        return Err(RuntimeError::OutputTooLarge(limits.output_bytes));
    }
    serde_json::from_str(&encoded).map_err(|_| RuntimeError::UnsupportedOutput)
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

pub fn execute_request(request: ExecuteRequest) -> ExecuteResponse {
    match execute(&request.script, &request.input, &RuntimeLimits::default()) {
        Ok(result) => ExecuteResponse::Ok { result },
        Err(error) => ExecuteResponse::Error {
            message: error.to_string(),
        },
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
    let encoded = serde_json::to_string(&response).unwrap_or_else(|_| {
        r#"{"status":"error","message":"failed to encode runtime response"}"#.to_string()
    });
    CString::new(encoded)
        .expect("JSON cannot contain NUL")
        .into_raw()
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
fn java_response(env: &jni::JNIEnv<'_>, response: &ExecuteResponse) -> jni::sys::jstring {
    let encoded = serde_json::to_string(response).unwrap_or_else(|_| {
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
}
