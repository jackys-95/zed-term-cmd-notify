//! Exercises bind and completion through the real Rust client and Swift socket server.
//!
//! `make socket-interop` starts the matching Swift driver and supplies an isolated
//! endpoint. Swift uses fake capture and delivery, so the check needs no running
//! Zed instance, Accessibility permission, or native notification delivery.
//!
//! With a socket path as its only argument, this example receives a binding token
//! and sends a completion with 31,000 elapsed milliseconds and exit code 7.
//! With `disconnect-then-recover` followed by a socket path, it first requires a
//! bind timeout, then checks a later bind and completion. The matching Swift mode
//! delays its first capture beyond the client's two-second exchange deadline.
//!
//! The Swift driver checks source-object identity and completion values. This
//! example checks the client's results and exits unsuccessfully on any mismatch.
//! The Makefile owns server startup and temporary-endpoint cleanup. The repository's
//! `docs/local-socket-transport.md` defines the transport contract.

use std::env;
use std::path::PathBuf;
use std::thread;
use std::time::Duration;

use zed_notify_local_client::transport::{Client, ClientError};

const ELAPSED_MS: u64 = 31_000;
const EXIT_CODE: u8 = 7;

fn main() {
    if let Err(error) = run() {
        eprintln!("socket interop failed: {error}");
        std::process::exit(1);
    }
}

/// Selects a command mode and checks its exchanges against the supplied endpoint.
///
/// The caller must start the matching Swift driver first. A socket path selects
/// normal bind/completion; `disconnect-then-recover` and a path select the timeout
/// scenario. Argument, endpoint, transport, and unexpected-response errors
/// propagate to `main`, which reports the failure and exits unsuccessfully.
fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut arguments = env::args_os().skip(1);
    let first_argument = arguments.next().ok_or("missing socket endpoint")?;
    let disconnect_mode = first_argument == std::ffi::OsStr::new("disconnect-then-recover");
    let socket_path = if disconnect_mode {
        arguments.next().ok_or("missing socket endpoint")?
    } else {
        first_argument
    };
    if arguments.next().is_some() {
        return Err("unexpected extra argument".into());
    }

    let client = Client::with_endpoint(PathBuf::from(socket_path))?;
    if disconnect_mode {
        return exercise_timeout_and_recovery(client);
    }

    let binding_id = client.bind()?;
    client.complete(binding_id, ELAPSED_MS, EXIT_CODE)?;
    println!("PASS: Rust client completed bind and completion over the socket.");
    Ok(())
}

/// Requires a bind timeout and checks that a later bind and completion succeed.
///
/// The Swift driver's first capture waits 2.3 seconds, exceeding this client's
/// two-second deadline. The client's owned socket closes when that exchange
/// returns an error. The later bind uses a new connection and obtains its own
/// token; the timed-out bind supplies no token to reuse.
///
/// The brief pause gives delayed capture more time to finish. Successful recovery
/// establishes service after the client timeout. Response attempts on separate
/// connections may finish in different orders.
///
/// Returns an error if the first bind succeeds, fails without a timeout, or either
/// later exchange fails. An accepted completion acknowledges request processing;
/// the Swift driver separately checks fake delivery.
fn exercise_timeout_and_recovery(client: Client) -> Result<(), Box<dyn std::error::Error>> {
    match client.bind() {
        Err(ClientError::TimedOut) => {
            println!("PASS: Rust client timed out while Swift capture was deliberately delayed.");
        }
        Err(error) => return Err(format!("expected a timeout, got {error}").into()),
        Ok(_) => return Err("expected the first bind to time out".into()),
    }

    // Pause briefly before checking whether a later exchange succeeds.
    thread::sleep(Duration::from_millis(500));
    let binding_id = client
        .bind()
        .map_err(|error| format!("second bind failed: {error}"))?;
    println!("PASS: Swift helper returned a binding after the Rust client timed out.");
    client
        .complete(binding_id, ELAPSED_MS, EXIT_CODE)
        .map_err(|error| format!("completion after peer disconnect failed: {error}"))?;
    println!("PASS: Rust completed a later exchange after the peer disconnect.");
    Ok(())
}
