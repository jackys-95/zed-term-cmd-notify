use serde::{Deserialize, Serialize};

pub const MAX_FRAME_BYTES: usize = 4 * 1024;
const FRAME_HEADER_BYTES: usize = 4;
const MAX_BINDING_ID_BYTES: usize = 128;
const PROTOCOL_VERSION: u8 = 1;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    Bind {
        version: u8,
    },
    Complete {
        version: u8,
        binding_id: String,
        elapsed_ms: u64,
        exit_code: u8,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    InvalidRequest,
    UnsupportedVersion,
    RequestTooLarge,
    SourceUnavailable,
    UnknownBinding,
}

impl ErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InvalidRequest => "invalid_request",
            Self::UnsupportedVersion => "unsupported_version",
            Self::RequestTooLarge => "request_too_large",
            Self::SourceUnavailable => "source_unavailable",
            Self::UnknownBinding => "unknown_binding",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case", deny_unknown_fields)]
pub enum Response {
    Bound { version: u8, binding_id: String },
    Accepted { version: u8 },
    Error { version: u8, error: ErrorCode },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProtocolError {
    EmptyFrame,
    FrameTooLarge,
    IncompleteFrame,
    TrailingData,
    InvalidRequest,
    InvalidBinding,
    UnsupportedVersion,
    InvalidResponse,
}

impl ProtocolError {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::EmptyFrame => "invalid_request",
            Self::FrameTooLarge => "request_too_large",
            Self::IncompleteFrame => "invalid_request",
            Self::TrailingData => "invalid_request",
            Self::InvalidRequest => "invalid_request",
            Self::InvalidBinding => "invalid_binding",
            Self::UnsupportedVersion => "unsupported_version",
            Self::InvalidResponse => "invalid_response",
        }
    }
}

fn validate_version(version: u8) -> Result<(), ProtocolError> {
    if version == PROTOCOL_VERSION {
        Ok(())
    } else {
        Err(ProtocolError::UnsupportedVersion)
    }
}

fn validate_binding_id(binding_id: &str) -> Result<(), ProtocolError> {
    if binding_id.is_empty()
        || binding_id.len() > MAX_BINDING_ID_BYTES
        || !binding_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
    {
        return Err(ProtocolError::InvalidBinding);
    }
    Ok(())
}

fn validate_request(request: &Request) -> Result<(), ProtocolError> {
    match request {
        Request::Bind { version } => validate_version(*version),
        Request::Complete {
            version,
            binding_id,
            ..
        } => {
            validate_version(*version)?;
            validate_binding_id(binding_id)
        }
    }
}

fn validate_response(response: &Response) -> Result<(), ProtocolError> {
    match response {
        Response::Bound {
            version,
            binding_id,
        } => {
            validate_version(*version)?;
            validate_binding_id(binding_id).map_err(|_| ProtocolError::InvalidResponse)
        }
        Response::Accepted { version } | Response::Error { version, .. } => {
            validate_version(*version)
        }
    }
}

fn check_payload_size(size: usize) -> Result<(), ProtocolError> {
    if size == 0 {
        return Err(ProtocolError::EmptyFrame);
    }
    if size > MAX_FRAME_BYTES {
        return Err(ProtocolError::FrameTooLarge);
    }
    Ok(())
}

pub fn encode_request(request: &Request) -> Result<Vec<u8>, ProtocolError> {
    validate_request(request)?;
    let payload = serde_json::to_vec(request).map_err(|_| ProtocolError::InvalidRequest)?;
    check_payload_size(payload.len())?;
    Ok(payload)
}

pub fn decode_request(payload: &[u8]) -> Result<Request, ProtocolError> {
    check_payload_size(payload.len())?;
    let request: Request =
        serde_json::from_slice(payload).map_err(|_| ProtocolError::InvalidRequest)?;
    validate_request(&request)?;
    Ok(request)
}

pub fn encode_response(response: &Response) -> Result<Vec<u8>, ProtocolError> {
    validate_response(response)?;
    let payload = serde_json::to_vec(response).map_err(|_| ProtocolError::InvalidResponse)?;
    check_payload_size(payload.len())?;
    Ok(payload)
}

pub fn decode_response(payload: &[u8]) -> Result<Response, ProtocolError> {
    check_payload_size(payload.len()).map_err(|_| ProtocolError::InvalidResponse)?;
    let response: Response =
        serde_json::from_slice(payload).map_err(|_| ProtocolError::InvalidResponse)?;
    validate_response(&response)?;
    Ok(response)
}

pub fn encode_frame(payload: &[u8]) -> Result<Vec<u8>, ProtocolError> {
    check_payload_size(payload.len())?;
    let length = u32::try_from(payload.len()).map_err(|_| ProtocolError::FrameTooLarge)?;
    let mut frame = Vec::with_capacity(FRAME_HEADER_BYTES + payload.len());
    frame.extend_from_slice(&length.to_be_bytes());
    frame.extend_from_slice(payload);
    Ok(frame)
}

#[derive(Default)]
pub struct FrameDecoder {
    buffer: Vec<u8>,
    complete: bool,
}

impl FrameDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds a stream chunk. `None` means the frame is incomplete; `Some` contains
    /// the payload once exactly one complete frame has arrived.
    pub fn push(&mut self, chunk: &[u8]) -> Result<Option<Vec<u8>>, ProtocolError> {
        if self.complete {
            return if chunk.is_empty() {
                Ok(None)
            } else {
                Err(ProtocolError::TrailingData)
            };
        }

        let max_buffer_size = FRAME_HEADER_BYTES + MAX_FRAME_BYTES;
        if chunk.len() > max_buffer_size - self.buffer.len() {
            return Err(ProtocolError::FrameTooLarge);
        }
        self.buffer.extend_from_slice(chunk);

        if self.buffer.len() < FRAME_HEADER_BYTES {
            return Ok(None);
        }

        let header: [u8; FRAME_HEADER_BYTES] = self.buffer[..FRAME_HEADER_BYTES]
            .try_into()
            .expect("the frame header length was checked");
        let payload_size = u32::from_be_bytes(header) as usize;
        check_payload_size(payload_size)?;

        let frame_size = FRAME_HEADER_BYTES + payload_size;
        if self.buffer.len() > frame_size {
            return Err(ProtocolError::TrailingData);
        }
        if self.buffer.len() < frame_size {
            return Ok(None);
        }

        self.complete = true;
        Ok(Some(self.buffer[FRAME_HEADER_BYTES..].to_vec()))
    }

    pub fn finish(&self) -> Result<(), ProtocolError> {
        if self.complete {
            Ok(())
        } else {
            Err(ProtocolError::IncompleteFrame)
        }
    }
}

pub fn decode_frame(frame: &[u8]) -> Result<Vec<u8>, ProtocolError> {
    let mut decoder = FrameDecoder::new();
    let payload = decoder.push(frame)?.ok_or(ProtocolError::IncompleteFrame)?;
    decoder.finish()?;
    Ok(payload)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;
    use serde_json::Value;

    const FIXTURES: &str = include_str!("../../../protocol/fixtures/messages.json");

    #[derive(Deserialize)]
    struct FixtureFile {
        valid_requests: Vec<PayloadFixture>,
        valid_responses: Vec<PayloadFixture>,
        invalid_requests: Vec<ErrorFixture>,
        invalid_responses: Vec<ErrorFixture>,
        invalid_json: Vec<RawFixture>,
        boundaries: BoundaryFixtures,
    }

    #[derive(Deserialize)]
    struct BoundaryFixtures {
        max_frame_bytes: usize,
        max_binding_id_bytes: usize,
        binding_id_character: String,
    }

    #[derive(Deserialize)]
    struct PayloadFixture {
        name: String,
        payload: Value,
    }

    #[derive(Deserialize)]
    struct ErrorFixture {
        name: String,
        payload: Value,
        error: String,
    }

    #[derive(Deserialize)]
    struct RawFixture {
        name: String,
        payload: String,
    }

    fn fixtures() -> FixtureFile {
        serde_json::from_str(FIXTURES).expect("shared protocol fixtures are valid JSON")
    }

    fn encode_fixture(value: &Value) -> Vec<u8> {
        serde_json::to_vec(value).expect("fixture payload serializes")
    }

    #[test]
    fn shared_valid_request_fixtures_decode_and_round_trip() {
        for fixture in fixtures().valid_requests {
            let request = decode_request(&encode_fixture(&fixture.payload))
                .unwrap_or_else(|error| panic!("{}: {error:?}", fixture.name));
            let encoded: Value = serde_json::from_slice(
                &encode_request(&request).expect("valid request re-encodes"),
            )
            .expect("encoded request is JSON");
            assert_eq!(encoded, fixture.payload, "{}", fixture.name);
        }
    }

    #[test]
    fn shared_valid_response_fixtures_decode_and_round_trip() {
        for fixture in fixtures().valid_responses {
            let response = decode_response(&encode_fixture(&fixture.payload))
                .unwrap_or_else(|error| panic!("{}: {error:?}", fixture.name));
            let encoded: Value = serde_json::from_slice(
                &encode_response(&response).expect("valid response re-encodes"),
            )
            .expect("encoded response is JSON");
            assert_eq!(encoded, fixture.payload, "{}", fixture.name);
        }
    }

    #[test]
    fn shared_invalid_request_fixtures_are_rejected() {
        for fixture in fixtures().invalid_requests {
            let error = decode_request(&encode_fixture(&fixture.payload))
                .expect_err("invalid request fixture must be rejected");
            assert_eq!(error.as_str(), fixture.error, "{}", fixture.name);
        }
    }

    #[test]
    fn shared_invalid_response_fixtures_are_rejected() {
        for fixture in fixtures().invalid_responses {
            let error = decode_response(&encode_fixture(&fixture.payload))
                .expect_err("invalid response fixture must be rejected");
            assert_eq!(error.as_str(), fixture.error, "{}", fixture.name);
        }
    }

    #[test]
    fn shared_malformed_json_fixtures_are_rejected() {
        for fixture in fixtures().invalid_json {
            let error = decode_request(fixture.payload.as_bytes())
                .expect_err("malformed JSON fixture must be rejected");
            assert_eq!(error, ProtocolError::InvalidRequest, "{}", fixture.name);
        }
    }

    #[test]
    fn shared_boundary_fixtures_are_enforced() {
        let boundaries = fixtures().boundaries;
        assert_eq!(MAX_FRAME_BYTES, boundaries.max_frame_bytes);
        assert_eq!(MAX_BINDING_ID_BYTES, boundaries.max_binding_id_bytes);

        let character = boundaries
            .binding_id_character
            .chars()
            .next()
            .expect("boundary fixture has a binding ID character");
        assert!(character.is_ascii());

        let valid_binding_id = character
            .to_string()
            .repeat(boundaries.max_binding_id_bytes);
        let valid_request = serde_json::json!({
            "version": 1,
            "type": "complete",
            "binding_id": valid_binding_id,
            "elapsed_ms": 1,
            "exit_code": 0
        });
        assert!(decode_request(&encode_fixture(&valid_request)).is_ok());

        let invalid_binding_id = character
            .to_string()
            .repeat(boundaries.max_binding_id_bytes + 1);
        let invalid_request = serde_json::json!({
            "version": 1,
            "type": "complete",
            "binding_id": invalid_binding_id,
            "elapsed_ms": 1,
            "exit_code": 0
        });
        assert_eq!(
            decode_request(&encode_fixture(&invalid_request)),
            Err(ProtocolError::InvalidBinding)
        );

        let valid_response = serde_json::json!({
            "version": 1,
            "status": "bound",
            "binding_id": character.to_string().repeat(boundaries.max_binding_id_bytes)
        });
        assert!(decode_response(&encode_fixture(&valid_response)).is_ok());

        let invalid_response = serde_json::json!({
            "version": 1,
            "status": "bound",
            "binding_id": character.to_string().repeat(boundaries.max_binding_id_bytes + 1)
        });
        assert_eq!(
            decode_response(&encode_fixture(&invalid_response)),
            Err(ProtocolError::InvalidResponse)
        );

        let max_payload = vec![b'x'; boundaries.max_frame_bytes];
        let max_frame = encode_frame(&max_payload).expect("the maximum payload is accepted");
        assert_eq!(
            max_frame.len(),
            boundaries.max_frame_bytes + FRAME_HEADER_BYTES
        );
        assert_eq!(decode_frame(&max_frame), Ok(max_payload));

        let oversized_payload = vec![b'x'; boundaries.max_frame_bytes + 1];
        assert_eq!(
            encode_frame(&oversized_payload),
            Err(ProtocolError::FrameTooLarge)
        );
    }

    #[test]
    fn frame_decoder_handles_partial_input() {
        let payload = encode_request(&Request::Bind { version: 1 }).unwrap();
        let frame = encode_frame(&payload).unwrap();
        let mut decoder = FrameDecoder::new();
        let mut decoded = None;

        for chunk in frame.chunks(2) {
            if let Some(payload) = decoder.push(chunk).unwrap() {
                decoded = Some(payload);
            }
        }

        assert_eq!(decoded, Some(payload));
        decoder.finish().unwrap();
    }

    #[test]
    fn frame_decoder_rejects_empty_oversized_incomplete_and_trailing_data() {
        assert_eq!(encode_frame(&[]), Err(ProtocolError::EmptyFrame));

        let oversized_header = ((MAX_FRAME_BYTES + 1) as u32).to_be_bytes();
        assert_eq!(
            FrameDecoder::new().push(&oversized_header),
            Err(ProtocolError::FrameTooLarge)
        );
        assert_eq!(
            encode_frame(&vec![b'x'; MAX_FRAME_BYTES + 1]),
            Err(ProtocolError::FrameTooLarge)
        );

        let frame = encode_frame(b"{}").unwrap();
        let mut incomplete = FrameDecoder::new();
        incomplete.push(&frame[..frame.len() - 1]).unwrap();
        assert_eq!(incomplete.finish(), Err(ProtocolError::IncompleteFrame));

        let mut trailing = FrameDecoder::new();
        trailing.push(&frame).unwrap();
        assert_eq!(trailing.push(b"x"), Err(ProtocolError::TrailingData));
    }
}
