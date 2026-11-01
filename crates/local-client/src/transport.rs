//! Sends binding and command-completion requests to the Swift macOS helper.
//!
//! The protocol module encodes and decodes messages. This module sends a request
//! and reads its response over a local Unix socket. Each message has a length
//! header followed by its JSON payload. The caller must start the helper
//! separately. See `docs/local-socket-transport.md` in the repository for the
//! endpoint, framing, and deadline rules.
//!
//! Each exchange uses one deadline measured by [`Instant`], a clock unaffected
//! by wall-clock changes. For example, if a response header arrives after
//! 1.5 seconds of the two-second budget, its payload and final EOF share the
//! remaining 0.5 seconds. The original deadline applies throughout the exchange.
//!
//! EOF (end of stream) confirms that the reply contains exactly one frame:
//! another byte is trailing data. If the helper keeps its sending side open,
//! the client can time out even after it has read the entire payload.
//!
//! Public methods wait for their result using nonblocking socket operations
//! and readiness waits. The client sends each request once. The helper may
//! have handled a request before the client times out.

use std::ffi::CString;
use std::fmt;
use std::io;
use std::mem::{size_of, zeroed};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::protocol::{
    ErrorCode, MAX_FRAME_BYTES, ProtocolError, Request, Response, decode_response, encode_frame,
    encode_request,
};

const SOCKET_PATH_BYTES: usize = 104;
const HEADER_BYTES: usize = 4;
const EXCHANGE_BUDGET: Duration = Duration::from_secs(2);

/// Explains why an endpoint could not be selected or a request could not finish.
#[derive(Debug)]
pub enum ClientError {
    /// The encoded socket path plus its terminating NUL exceeds 104 bytes.
    EndpointTooLong,
    /// The path, endpoint type, owner, or permissions fail validation.
    InvalidEndpoint,
    /// The endpoint is missing or refused, or the socket reports a reset or no connection.
    Unavailable,
    /// The exchange budget expired; the helper may already have acted.
    TimedOut,
    /// A request or response violates the message or framing contract.
    Protocol(ProtocolError),
    /// The helper returned an explicit rejection, such as an unknown binding.
    Service(ErrorCode),
    /// A filesystem or socket operation failed with another operating-system error.
    Io(io::Error),
}

impl fmt::Display for ClientError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EndpointTooLong => formatter.write_str("local helper endpoint is too long"),
            Self::InvalidEndpoint => formatter.write_str("local helper endpoint is unsafe"),
            Self::Unavailable => formatter.write_str("local helper is unavailable"),
            Self::TimedOut => formatter.write_str("local helper request timed out"),
            Self::Protocol(error) => write!(formatter, "local helper protocol error: {error:?}"),
            Self::Service(error) => write!(formatter, "local helper rejected request: {error:?}"),
            Self::Io(error) => write!(formatter, "local helper I/O failed: {error}"),
        }
    }
}

impl std::error::Error for ClientError {}

impl From<ProtocolError> for ClientError {
    fn from(error: ProtocolError) -> Self {
        Self::Protocol(error)
    }
}

/// Sends requests to the per-user macOS helper using a fresh connection each time.
///
/// This value stores an endpoint and time budget; it holds no open socket or
/// cached binding. Production callers should use [`Client::for_current_user`].
///
/// [`Client::bind`] and [`Client::complete`] return [`ClientError`] for an unsafe
/// or unavailable endpoint, a timeout, an invalid message, a helper rejection,
/// or another filesystem or socket error.
///
/// # Examples
///
/// This example requires a running helper with the required macOS permissions.
/// The caller must check terminal eligibility and bind while the intended
/// source window is foreground. The completion values below are synthetic;
/// shell hooks will supply the actual command duration and exit status.
///
/// ```no_run
/// use zed_notify_local_client::transport::{Client, ClientError};
///
/// # fn main() -> Result<(), ClientError> {
/// let client = Client::for_current_user()?;
/// let binding_id = client.bind()?;
/// client.complete(binding_id, 30_000, 0)?;
/// # Ok(())
/// # }
/// ```
#[derive(Clone, Debug)]
pub struct Client {
    socket_path: PathBuf,
    exchange_budget: Duration,
}

impl Client {
    /// Selects the helper socket under the current user's Application Support directory.
    ///
    /// Reads `HOME` and validates the pathname. This does not connect, create
    /// endpoint files, or start the helper.
    ///
    /// # Errors
    ///
    /// Returns [`ClientError::InvalidEndpoint`] if `HOME` is unavailable or the
    /// pathname is invalid, or [`ClientError::EndpointTooLong`] if it cannot fit.
    pub fn for_current_user() -> Result<Self, ClientError> {
        let home = std::env::var_os("HOME").ok_or(ClientError::InvalidEndpoint)?;
        let socket_path = PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("zed-term-cmd-notify")
            .join("helper.sock");
        Self::with_endpoint(socket_path)
    }

    /// Selects an explicit socket pathname, primarily for isolated tests.
    ///
    /// Only the pathname is validated here. Each request checks the existing
    /// parent directory and socket for the current owner and modes `0700` and
    /// `0600`, respectively; this constructor neither creates nor repairs them.
    ///
    /// # Errors
    ///
    /// Returns [`ClientError::InvalidEndpoint`] for an empty path or embedded
    /// NUL, or [`ClientError::EndpointTooLong`] for an overlength encoded path.
    pub fn with_endpoint(socket_path: impl Into<PathBuf>) -> Result<Self, ClientError> {
        let socket_path = socket_path.into();
        validate_socket_path(&socket_path)?;
        Ok(Self {
            socket_path,
            exchange_budget: EXCHANGE_BUDGET,
        })
    }

    #[cfg(test)]
    fn with_budget(
        socket_path: impl Into<PathBuf>,
        exchange_budget: Duration,
    ) -> Result<Self, ClientError> {
        let mut client = Self::with_endpoint(socket_path)?;
        client.exchange_budget = exchange_budget;
        Ok(client)
    }

    /// Asks the helper to capture the source window and returns its opaque binding ID.
    ///
    /// Call while the intended source window is foreground. The helper retains
    /// the window object; the caller stores the returned ID for later completion.
    ///
    /// # Errors
    ///
    /// The helper may still capture the window after the client times out.
    /// The caller receives no binding ID to cache in that case.
    /// A later eligible command launch may try binding again.
    pub fn bind(&self) -> Result<String, ClientError> {
        match self.exchange(Request::Bind { version: 1 })? {
            Response::Bound { binding_id, .. } => Ok(binding_id),
            Response::Error { error, .. } => Err(ClientError::Service(error)),
            _ => Err(ClientError::Protocol(ProtocolError::InvalidResponse)),
        }
    }

    /// Reports a finished command using the binding ID selected by the caller.
    ///
    /// `elapsed_ms` is the command's duration in milliseconds, and `exit_code`
    /// is its shell exit status. Success acknowledges processing; notification
    /// policy may suppress delivery, so it does not guarantee a visible alert.
    ///
    /// # Errors
    ///
    /// The helper may already have processed a completion when the client times
    /// out. A timeout alone does not show that the binding is invalid.
    /// Do not automatically resend the completion, as this could duplicate delivery.
    pub fn complete(
        &self,
        binding_id: impl Into<String>,
        elapsed_ms: u64,
        exit_code: u8,
    ) -> Result<(), ClientError> {
        match self.exchange(Request::Complete {
            version: 1,
            binding_id: binding_id.into(),
            elapsed_ms,
            exit_code,
        })? {
            Response::Accepted { .. } => Ok(()),
            Response::Error { error, .. } => Err(ClientError::Service(error)),
            _ => Err(ClientError::Protocol(ProtocolError::InvalidResponse)),
        }
    }

    /// Exchanges exactly one frame in each direction under a shared deadline.
    ///
    /// The timeout starts after the endpoint checks. The local `OwnedFd` owns
    /// the socket and closes it when this function returns. This includes early
    /// returns through `?`, Rust's operator for propagating errors.
    /// Descriptor helpers borrow the socket while `OwnedFd` keeps ownership.
    fn exchange(&self, request: Request) -> Result<Response, ClientError> {
        validate_client_endpoint(&self.socket_path)?;
        let deadline = Instant::now() + self.exchange_budget;
        let socket = connect_nonblocking(&self.socket_path, deadline)?;
        let payload = encode_request(&request)?;
        let frame = encode_frame(&payload)?;
        write_all(socket.as_raw_fd(), &frame, deadline)?;

        // End the request direction while keeping the response direction open.
        // SAFETY: socket owns a live descriptor, and SHUT_WR is a valid direction.
        if unsafe { libc::shutdown(socket.as_raw_fd(), libc::SHUT_WR) } != 0 {
            return Err(classify_io(io::Error::last_os_error()));
        }

        let mut header = [0u8; HEADER_BYTES];
        read_exact(socket.as_raw_fd(), &mut header, deadline)?;
        let payload_length = u32::from_be_bytes(header) as usize;
        if payload_length == 0 {
            return Err(ClientError::Protocol(ProtocolError::EmptyFrame));
        }
        if payload_length > MAX_FRAME_BYTES {
            return Err(ClientError::Protocol(ProtocolError::FrameTooLarge));
        }

        let mut response_payload = vec![0u8; payload_length];
        read_exact(socket.as_raw_fd(), &mut response_payload, deadline)?;
        require_eof(socket.as_raw_fd(), deadline)?;
        decode_response(&response_payload).map_err(ClientError::Protocol)
    }
}

/// Validates encoded pathname bytes and returns the NUL-terminated C representation.
///
/// For example, 103 pathname bytes plus one NUL fit; 104 plus one do not.
/// Count bytes rather than characters, since non-ASCII characters can use more
/// than one byte. No filesystem lookup is needed.
fn validate_socket_path(path: &Path) -> Result<CString, ClientError> {
    let bytes = path.as_os_str().as_bytes();
    if bytes.is_empty() || bytes.contains(&0) {
        return Err(ClientError::InvalidEndpoint);
    }
    if bytes.len() + 1 > SOCKET_PATH_BYTES {
        return Err(ClientError::EndpointTooLong);
    }
    CString::new(bytes).map_err(|_| ClientError::InvalidEndpoint)
}

/// Checks the immediate parent directory and socket without following their symlinks.
fn validate_client_endpoint(socket_path: &Path) -> Result<(), ClientError> {
    // The path limit is checked before the first filesystem lookup.
    validate_socket_path(socket_path)?;

    let parent = socket_path.parent().ok_or(ClientError::InvalidEndpoint)?;
    let directory = std::fs::symlink_metadata(parent).map_err(classify_io)?;
    // SAFETY: geteuid takes no arguments and requires no pointer or resource setup.
    if !directory.file_type().is_dir()
        || directory.uid() != unsafe { libc::geteuid() }
        || directory.mode() & 0o7777 != 0o700
    {
        return Err(ClientError::InvalidEndpoint);
    }

    let socket = std::fs::symlink_metadata(socket_path).map_err(classify_io)?;
    // SAFETY: geteuid has the same argument-free contract as above.
    if !socket.file_type().is_socket()
        || socket.uid() != unsafe { libc::geteuid() }
        || socket.mode() & 0o7777 != 0o600
    {
        return Err(ClientError::InvalidEndpoint);
    }
    Ok(())
}

#[cfg(unix)]
use std::os::unix::fs::{FileTypeExt, MetadataExt};

/// Creates and connects an owned socket, waiting for readiness only within the deadline.
fn connect_nonblocking(path: &Path, deadline: Instant) -> Result<OwnedFd, ClientError> {
    let path_c = validate_socket_path(path)?;
    ensure_before_deadline(deadline)?;
    // SAFETY: these constants select a Unix stream socket; no pointers are passed.
    let descriptor = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if descriptor < 0 {
        return Err(classify_io(io::Error::last_os_error()));
    }
    // SAFETY: libc::socket returned a nonnegative descriptor with no existing Rust owner.
    // Ownership transfers once, so every later error also closes the descriptor.
    let socket = unsafe { OwnedFd::from_raw_fd(descriptor) };

    set_nonblocking(socket.as_raw_fd())?;
    set_close_on_exec(socket.as_raw_fd())?;

    #[cfg(target_os = "macos")]
    set_socket_option(socket.as_raw_fd(), libc::SOL_SOCKET, libc::SO_NOSIGPIPE, 1)?;

    // SAFETY: sockaddr_un contains integer fields and an array, all valid when zeroed.
    let mut address: libc::sockaddr_un = unsafe { zeroed() };
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    let path_bytes = path_c.as_bytes_with_nul();
    for (index, byte) in path_bytes.iter().enumerate() {
        address.sun_path[index] = *byte as libc::c_char;
    }

    #[cfg(target_os = "macos")]
    {
        address.sun_len = (size_of::<libc::sa_family_t>() + 1 + path_bytes.len()) as u8;
    }

    let address_length = (size_of::<libc::sa_family_t>() + 1 + path_bytes.len()) as libc::socklen_t;
    // SAFETY: socket remains owned, address is initialized and lives through the
    // call, and the validated pathname keeps address_length within its allocation.
    let result = unsafe {
        libc::connect(
            socket.as_raw_fd(),
            &address as *const libc::sockaddr_un as *const libc::sockaddr,
            address_length,
        )
    };
    ensure_before_deadline(deadline)?;
    if result == 0 {
        return Ok(socket);
    }

    let error = io::Error::last_os_error();
    match error.raw_os_error() {
        Some(libc::EINPROGRESS)
        | Some(libc::EALREADY)
        | Some(libc::EINTR)
        | Some(libc::EWOULDBLOCK) => {
            wait_ready(socket.as_raw_fd(), libc::POLLOUT, deadline)?;
            let socket_error = socket_pending_error(socket.as_raw_fd())?;
            if socket_error == 0 {
                ensure_before_deadline(deadline)?;
                Ok(socket)
            } else {
                Err(classify_io(io::Error::from_raw_os_error(socket_error)))
            }
        }
        _ => Err(classify_io(error)),
    }
}

fn set_nonblocking(descriptor: RawFd) -> Result<(), ClientError> {
    // SAFETY: the caller keeps the descriptor open through both fcntl calls.
    // F_GETFL takes only the descriptor and command. F_SETFL takes integer flags.
    let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(descriptor, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
    {
        return Err(classify_io(io::Error::last_os_error()));
    }
    Ok(())
}

fn set_close_on_exec(descriptor: RawFd) -> Result<(), ClientError> {
    // SAFETY: the caller keeps the descriptor open through both fcntl calls.
    // F_GETFD takes only the descriptor and command. F_SETFD takes integer flags.
    let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFD) };
    if flags < 0 || unsafe { libc::fcntl(descriptor, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0
    {
        return Err(classify_io(io::Error::last_os_error()));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn set_socket_option(
    descriptor: RawFd,
    level: libc::c_int,
    option: libc::c_int,
    value: libc::c_int,
) -> Result<(), ClientError> {
    // SAFETY: the caller keeps the socket open during the call. The option expects
    // an integer. The pointer to value stays readable for the supplied byte count.
    let result = unsafe {
        libc::setsockopt(
            descriptor,
            level,
            option,
            &value as *const libc::c_int as *const libc::c_void,
            size_of::<libc::c_int>() as libc::socklen_t,
        )
    };
    if result != 0 {
        return Err(classify_io(io::Error::last_os_error()));
    }
    Ok(())
}

/// Reads the connection result after readiness; a writable socket may still have failed.
fn socket_pending_error(descriptor: RawFd) -> Result<i32, ClientError> {
    let mut error = 0;
    let mut length = size_of::<libc::c_int>() as libc::socklen_t;
    // SAFETY: the caller keeps the socket open during the call. SO_ERROR writes
    // an integer into error. length supplies the buffer size. Both variables
    // remain alive and writable during the call.
    let result = unsafe {
        libc::getsockopt(
            descriptor,
            libc::SOL_SOCKET,
            libc::SO_ERROR,
            &mut error as *mut libc::c_int as *mut libc::c_void,
            &mut length,
        )
    };
    if result != 0 {
        return Err(classify_io(io::Error::last_os_error()));
    }
    Ok(error)
}

/// Waits until an operation can be retried, including after a hangup or socket error.
///
/// Readiness does not guarantee success. The caller retries the socket operation
/// or reads its pending error to distinguish progress, EOF, and failure.
fn wait_ready(
    descriptor: RawFd,
    events: libc::c_short,
    deadline: Instant,
) -> Result<(), ClientError> {
    loop {
        ensure_before_deadline(deadline)?;
        let timeout = poll_timeout_ms(deadline)?;
        let mut poll_descriptor = libc::pollfd {
            fd: descriptor,
            events,
            revents: 0,
        };
        // SAFETY: poll_descriptor is one initialized, writable entry that lives
        // through the call, and the entry count is exactly one.
        let result = unsafe { libc::poll(&mut poll_descriptor, 1, timeout) };
        if result > 0 {
            if poll_descriptor.revents & libc::POLLNVAL != 0 {
                return Err(ClientError::Io(io::Error::from_raw_os_error(libc::EBADF)));
            }
            return Ok(());
        }
        if result == 0 {
            return Err(ClientError::TimedOut);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(classify_io(error));
        }
    }
}

fn poll_timeout_ms(deadline: Instant) -> Result<libc::c_int, ClientError> {
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .ok_or(ClientError::TimedOut)?;
    // Round up so a positive fraction of a millisecond does not become a busy poll.
    let millis = remaining.as_nanos().div_ceil(1_000_000);
    Ok(millis.clamp(1, libc::c_int::MAX as u128) as libc::c_int)
}

/// Fills a buffer, advancing only the unfilled slice after each partial read.
///
/// For a four-byte header received as one byte then three, the second read uses
/// only the remaining three-byte slice. Both reads use the original deadline.
fn read_exact(
    descriptor: RawFd,
    mut buffer: &mut [u8],
    deadline: Instant,
) -> Result<(), ClientError> {
    while !buffer.is_empty() {
        ensure_before_deadline(deadline)?;
        // SAFETY: the caller retains the socket, and buffer is exclusively
        // writable for buffer.len() bytes and lives through this synchronous call.
        let result = unsafe {
            libc::recv(
                descriptor,
                buffer.as_mut_ptr() as *mut libc::c_void,
                buffer.len(),
                0,
            )
        };
        if result > 0 {
            let read = result as usize;
            buffer = &mut buffer[read..];
            continue;
        }
        if result == 0 {
            return Err(ClientError::Protocol(ProtocolError::IncompleteFrame));
        }
        let error = io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::EINTR) => continue,
            Some(code) if code == libc::EAGAIN || code == libc::EWOULDBLOCK => {
                wait_ready(descriptor, libc::POLLIN, deadline)?;
            }
            _ => return Err(classify_io(error)),
        }
    }
    ensure_before_deadline(deadline)
}

/// Sends the remaining slice after each partial write without resetting the deadline.
fn write_all(descriptor: RawFd, mut buffer: &[u8], deadline: Instant) -> Result<(), ClientError> {
    while !buffer.is_empty() {
        ensure_before_deadline(deadline)?;
        // SAFETY: the caller retains the socket, and buffer remains readable for
        // buffer.len() bytes through this synchronous call.
        let result = unsafe {
            libc::send(
                descriptor,
                buffer.as_ptr() as *const libc::c_void,
                buffer.len(),
                0,
            )
        };
        if result > 0 {
            buffer = &buffer[result as usize..];
            continue;
        }
        if result == 0 {
            return Err(ClientError::Io(io::Error::new(
                io::ErrorKind::WriteZero,
                "socket write returned zero",
            )));
        }
        let error = io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::EINTR) => continue,
            Some(code) if code == libc::EAGAIN || code == libc::EWOULDBLOCK => {
                wait_ready(descriptor, libc::POLLOUT, deadline)?;
            }
            _ => return Err(classify_io(error)),
        }
    }
    ensure_before_deadline(deadline)
}

/// Requires EOF after the response payload.
fn require_eof(descriptor: RawFd, deadline: Instant) -> Result<(), ClientError> {
    let mut byte = 0u8;
    loop {
        ensure_before_deadline(deadline)?;
        // SAFETY: the caller retains the socket, and byte is a writable one-byte
        // allocation that lives through the call.
        let result =
            unsafe { libc::recv(descriptor, &mut byte as *mut u8 as *mut libc::c_void, 1, 0) };
        if result == 0 {
            ensure_before_deadline(deadline)?;
            return Ok(());
        }
        if result > 0 {
            return Err(ClientError::Protocol(ProtocolError::TrailingData));
        }
        let error = io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::EINTR) => continue,
            Some(code) if code == libc::EAGAIN || code == libc::EWOULDBLOCK => {
                wait_ready(descriptor, libc::POLLIN, deadline)?;
            }
            _ => return Err(classify_io(error)),
        }
    }
}

fn classify_io(error: io::Error) -> ClientError {
    match error.raw_os_error() {
        Some(libc::ENOENT)
        | Some(libc::ECONNREFUSED)
        | Some(libc::ECONNRESET)
        | Some(libc::ENOTCONN) => ClientError::Unavailable,
        Some(libc::ETIMEDOUT) => ClientError::TimedOut,
        _ if error.kind() == io::ErrorKind::TimedOut => ClientError::TimedOut,
        _ => ClientError::Io(error),
    }
}

fn ensure_before_deadline(deadline: Instant) -> Result<(), ClientError> {
    if Instant::now() < deadline {
        Ok(())
    } else {
        Err(ClientError::TimedOut)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{Response, decode_request, encode_response};
    use std::io::{Read, Write};
    use std::net::Shutdown;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::thread::{self, JoinHandle};

    static NEXT_TEMP_ID: AtomicU64 = AtomicU64::new(0);

    struct TestEndpoint {
        root: PathBuf,
        socket_path: PathBuf,
    }

    impl TestEndpoint {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "zed-notify-client-{}-{}",
                std::process::id(),
                NEXT_TEMP_ID.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir(&root).expect("create isolated endpoint directory");
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
                .expect("set private directory mode");
            let socket_path = root.join("helper.sock");
            Self { root, socket_path }
        }

        fn listener(&self) -> UnixListener {
            let listener =
                UnixListener::bind(&self.socket_path).expect("bind isolated Unix socket");
            std::fs::set_permissions(&self.socket_path, std::fs::Permissions::from_mode(0o600))
                .expect("set private socket mode");
            listener
        }

        fn client(&self, budget: Duration) -> Client {
            Client::with_budget(self.socket_path.clone(), budget)
                .expect("construct client for isolated endpoint")
        }
    }

    impl Drop for TestEndpoint {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn read_bind_request(stream: &mut UnixStream) {
        let mut header = [0u8; HEADER_BYTES];
        stream.read_exact(&mut header).expect("read request header");
        let length = u32::from_be_bytes(header) as usize;
        let mut payload = vec![0; length];
        stream
            .read_exact(&mut payload)
            .expect("read complete request payload");
        assert_eq!(decode_request(&payload), Ok(Request::Bind { version: 1 }));
        let mut trailing = [0u8; 1];
        assert_eq!(
            stream.read(&mut trailing).expect("read request EOF"),
            0,
            "client must half-close after one request"
        );
    }

    enum MockResponseBehavior {
        Immediate,
        Fragmented,
        Delayed(Duration),
        WithholdEof(Duration),
        SlowFragments {
            initial_delay: Duration,
            interval: Duration,
        },
    }

    fn mock_response_server(
        listener: UnixListener,
        response_frame: Vec<u8>,
        behavior: MockResponseBehavior,
    ) -> JoinHandle<()> {
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept client");
            stream
                .set_read_timeout(Some(Duration::from_secs(1)))
                .expect("bound mock read time");
            stream
                .set_write_timeout(Some(Duration::from_secs(1)))
                .expect("bound mock write time");
            read_bind_request(&mut stream);

            match behavior {
                MockResponseBehavior::Immediate => {
                    let _ = stream.write_all(&response_frame);
                }
                MockResponseBehavior::Fragmented => {
                    for byte in response_frame {
                        if stream.write_all(&[byte]).is_err() {
                            break;
                        }
                        thread::yield_now();
                    }
                }
                MockResponseBehavior::Delayed(delay) => {
                    thread::sleep(delay);
                    let _ = stream.write_all(&response_frame);
                }
                MockResponseBehavior::WithholdEof(hold_open) => {
                    stream
                        .write_all(&response_frame)
                        .expect("write complete response before withholding EOF");
                    thread::sleep(hold_open);
                }
                MockResponseBehavior::SlowFragments {
                    initial_delay,
                    interval,
                } => {
                    thread::sleep(initial_delay);
                    for (index, byte) in response_frame.into_iter().enumerate() {
                        if index > 0 {
                            thread::sleep(interval);
                        }
                        if stream.write_all(&[byte]).is_err() {
                            break;
                        }
                    }
                }
            }

            let _ = stream.shutdown(Shutdown::Write);
        })
    }

    fn bound_response_frame() -> Vec<u8> {
        encode_frame(
            &encode_response(&Response::Bound {
                version: 1,
                binding_id: "mock_binding".to_owned(),
            })
            .expect("encode mock response"),
        )
        .expect("frame mock response")
    }

    #[test]
    fn socket_path_limit_counts_the_terminating_nul() {
        let accepted = PathBuf::from(format!("/{}", "x".repeat(SOCKET_PATH_BYTES - 2)));
        assert!(validate_socket_path(&accepted).is_ok());

        let rejected = PathBuf::from(format!("/{}", "x".repeat(SOCKET_PATH_BYTES - 1)));
        assert!(matches!(
            validate_socket_path(&rejected),
            Err(ClientError::EndpointTooLong)
        ));
    }

    #[test]
    fn client_rejects_a_regular_file_at_the_socket_path() {
        let endpoint = TestEndpoint::new();
        std::fs::write(&endpoint.socket_path, b"not a socket").expect("create unexpected endpoint");
        std::fs::set_permissions(
            &endpoint.socket_path,
            std::fs::Permissions::from_mode(0o600),
        )
        .expect("set endpoint file mode");

        assert!(matches!(
            validate_client_endpoint(&endpoint.socket_path),
            Err(ClientError::InvalidEndpoint)
        ));
    }

    #[test]
    fn missing_helper_is_reported_as_unavailable() {
        let endpoint = TestEndpoint::new();
        assert!(matches!(
            endpoint.client(Duration::from_secs(1)).bind(),
            Err(ClientError::Unavailable)
        ));
    }

    #[test]
    fn fragmented_response_is_read_to_eof() {
        let endpoint = TestEndpoint::new();
        let listener = endpoint.listener();
        let server = mock_response_server(
            listener,
            bound_response_frame(),
            MockResponseBehavior::Fragmented,
        );

        assert!(matches!(
            endpoint.client(Duration::from_secs(1)).bind(),
            Ok(binding_id) if binding_id == "mock_binding"
        ));
        server.join().expect("mock server completes");
    }

    #[test]
    fn malformed_oversized_incomplete_and_trailing_responses_are_rejected() {
        let cases = [
            (
                encode_frame(b"{").expect("frame malformed JSON"),
                ProtocolError::InvalidResponse,
            ),
            (
                ((MAX_FRAME_BYTES + 1) as u32).to_be_bytes().to_vec(),
                ProtocolError::FrameTooLarge,
            ),
            (
                [5u32.to_be_bytes().as_slice(), b"{}"].concat(),
                ProtocolError::IncompleteFrame,
            ),
            (
                [bound_response_frame().as_slice(), b"x"].concat(),
                ProtocolError::TrailingData,
            ),
        ];

        for (frame, expected_error) in cases {
            let endpoint = TestEndpoint::new();
            let listener = endpoint.listener();
            let server = mock_response_server(listener, frame, MockResponseBehavior::Immediate);
            assert!(matches!(
                endpoint.client(Duration::from_secs(1)).bind(),
                Err(ClientError::Protocol(error)) if error == expected_error
            ));
            server.join().expect("mock server completes");
        }
    }

    #[test]
    fn a_stalled_response_expires_at_the_exchange_deadline() {
        let endpoint = TestEndpoint::new();
        let listener = endpoint.listener();
        let server = mock_response_server(
            listener,
            bound_response_frame(),
            MockResponseBehavior::Delayed(Duration::from_millis(150)),
        );

        assert!(matches!(
            endpoint.client(Duration::from_millis(40)).bind(),
            Err(ClientError::TimedOut)
        ));
        server
            .join()
            .expect("mock server handles the closed client");
    }

    #[test]
    fn a_valid_response_with_withheld_eof_times_out_at_the_exchange_deadline() {
        let endpoint = TestEndpoint::new();
        let listener = endpoint.listener();
        let server = mock_response_server(
            listener,
            bound_response_frame(),
            MockResponseBehavior::WithholdEof(Duration::from_millis(150)),
        );

        assert!(matches!(
            endpoint.client(Duration::from_millis(40)).bind(),
            Err(ClientError::TimedOut)
        ));
        server
            .join()
            .expect("mock server closes after the hold interval");
    }

    #[test]
    fn slow_fragments_share_the_original_exchange_deadline() {
        let endpoint = TestEndpoint::new();
        let listener = endpoint.listener();
        let server = mock_response_server(
            listener,
            bound_response_frame(),
            MockResponseBehavior::SlowFragments {
                initial_delay: Duration::from_millis(130),
                interval: Duration::from_millis(2),
            },
        );

        assert!(matches!(
            endpoint.client(Duration::from_millis(200)).bind(),
            Err(ClientError::TimedOut)
        ));
        server
            .join()
            .expect("mock server handles the closed client");
    }
}
