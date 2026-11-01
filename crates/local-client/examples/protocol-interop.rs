use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use zed_notify_local_client::protocol::{
    Request, Response, decode_frame, decode_response, encode_frame, encode_request,
};

const BINDING_ID: &str = "interop_binding_01";
const ELAPSED_MS: u64 = 31_000;

fn main() {
    if let Err(error) = run() {
        eprintln!("protocol interop failed: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let mut arguments = env::args().skip(1);
    let command = arguments
        .next()
        .ok_or_else(|| "missing command".to_owned())?;
    let directory = PathBuf::from(
        arguments
            .next()
            .ok_or_else(|| "missing exchange directory".to_owned())?,
    );
    if arguments.next().is_some() {
        return Err("unexpected extra argument".to_owned());
    }

    match command.as_str() {
        "emit-requests" => emit_requests(&directory),
        "verify-responses" => verify_responses(&directory),
        _ => Err("unknown command".to_owned()),
    }
}

fn emit_requests(directory: &Path) -> Result<(), String> {
    fs::create_dir_all(directory).map_err(|error| format!("create exchange directory: {error}"))?;
    let requests = [
        ("bind-request.frame", Request::Bind { version: 1 }),
        (
            "complete-request.frame",
            Request::Complete {
                version: 1,
                binding_id: BINDING_ID.to_owned(),
                elapsed_ms: ELAPSED_MS,
                exit_code: 0,
            },
        ),
    ];

    for (filename, request) in requests {
        let payload =
            encode_request(&request).map_err(|error| format!("encode request: {error:?}"))?;
        let frame = encode_frame(&payload).map_err(|error| format!("frame request: {error:?}"))?;
        fs::write(directory.join(filename), frame)
            .map_err(|error| format!("write request frame: {error}"))?;
    }
    Ok(())
}

fn verify_responses(directory: &Path) -> Result<(), String> {
    let expected_responses = [
        (
            "bound-response.frame",
            Response::Bound {
                version: 1,
                binding_id: BINDING_ID.to_owned(),
            },
        ),
        ("accepted-response.frame", Response::Accepted { version: 1 }),
    ];

    for (filename, expected) in expected_responses {
        let frame = fs::read(directory.join(filename))
            .map_err(|error| format!("read response frame: {error}"))?;
        let payload = decode_frame(&frame).map_err(|error| format!("decode frame: {error:?}"))?;
        let response =
            decode_response(&payload).map_err(|error| format!("decode response: {error:?}"))?;
        if response != expected {
            return Err(format!("unexpected response in {filename}"));
        }
    }
    Ok(())
}
