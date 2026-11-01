# Protocol v1

**Status:** Provisional. This initial protocol establishes the Rust/Swift test foundation and may change as runtime integration is implemented.

Rust and Swift exchange one request and one response per connection. Each message is a four-byte unsigned big-endian payload length followed by that many UTF-8 JSON bytes. The payload limit is 4 KiB; empty or larger frames are rejected. Receivers must handle partial reads and must not allocate based on a length larger than the limit. A transport writing an encoded frame must write all of its bytes.

Every JSON message includes `version: 1`. Unknown fields are rejected. Binding IDs are opaque, nonempty ASCII strings up to 128 bytes, using only letters, digits, `_`, and `-`. This keeps messages bounded and avoids sending command text, window titles, paths, or host-specific data.

## Requests

Bind to the currently eligible source window:

```json
{"version":1,"type":"bind"}
```

The same request is used for manual rebind. A successful bind returns a fresh binding ID; callers replace their current cache with it. Previously issued IDs remain valid for already launched commands and issued notifications.

Report a completed command:

```json
{"version":1,"type":"complete","binding_id":"fixture_binding_01","elapsed_ms":31000,"exit_code":0}
```

`elapsed_ms` is an unsigned 64-bit integer. `exit_code` is an unsigned 8-bit integer. No command text or terminal data is sent.

## Responses

A successful bind returns:

```json
{"version":1,"status":"bound","binding_id":"fixture_binding_01"}
```

A completion accepted for processing returns:

```json
{"version":1,"status":"accepted"}
```

`accepted` acknowledges protocol processing; it does not promise a visible notification. A failed request returns `status: "error"` with one of `invalid_request`, `unsupported_version`, `request_too_large`, `source_unavailable`, or `unknown_binding`.

An absent binding is not represented as a completion request. The caller's behavior when no binding is available remains an open policy decision.

## Shared fixtures and checks

[`fixtures/messages.json`](fixtures/messages.json) contains synthetic valid and invalid request/response payloads and the shared 4 KiB frame and 128-byte binding ID limits. Rust and Swift tests consume this same file. They cover missing fields, invalid numeric values, malformed JSON, partial input, incomplete frames, trailing bytes, and the exact size boundaries.

`make protocol-interop` exercises the runtime directions: Rust encodes bind and complete requests for Swift to decode, then Swift encodes bound and accepted responses for Rust to decode. `make test` runs this exchange alongside both unit suites.

These definitions specify the wire contract only. Socket setup, deadlines, notification policy, and OS-level delivery are implemented and validated in their respective slices.
