use gamealgo_script_runtime::{ExecuteRequest, execute_request};
use std::io::{self, Read};

fn main() {
    let mut input = String::new();
    if let Err(error) = io::stdin().read_to_string(&mut input) {
        eprintln!("failed to read runtime request: {error}");
        std::process::exit(2);
    }
    let response = match serde_json::from_str::<ExecuteRequest>(&input) {
        Ok(request) => execute_request(request),
        Err(error) => gamealgo_script_runtime::ExecuteResponse::Error {
            message: format!("invalid request: {error}"),
        },
    };
    println!(
        "{}",
        serde_json::to_string(&response).expect("response JSON")
    );
}
