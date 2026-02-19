mod error;
mod request;
mod response;

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::time::Duration;

use base64::{engine::general_purpose::STANDARD, Engine as _};
use error::NativeError;
use request::NativeRequest;
use response::NativeResponse;
use rustler::{types::atom::Atom, NifResult};
use serde_json::{json, Value};
use wreq::{Client, Method};
use wreq_util::Emulation;

rustler::atoms! {
    ok,
    error
}

fn run_with_panic_protection<F>(f: F) -> Result<NativeResponse, NativeError>
where
    F: FnOnce() -> Result<NativeResponse, NativeError>,
{
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(result) => result,
        Err(panic_info) => {
            let message = panic_info
                .downcast_ref::<String>()
                .map(|s| s.as_str())
                .or_else(|| panic_info.downcast_ref::<&str>().copied())
                .unwrap_or("unknown panic");
            Err(NativeError::new("nif_panic", message, json!({})))
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn nif_perform_request(payload: String) -> NifResult<(Atom, String)> {
    let request: NativeRequest = match serde_json::from_str(&payload) {
        Ok(value) => value,
        Err(reason) => {
            let decode_error = NativeError::new(
                "decode_request",
                "invalid request payload",
                json!({"reason": reason.to_string()}),
            );

            return Ok((error(), decode_error.encode()));
        }
    };

    let result = run_with_panic_protection(|| execute_request(request));

    match result {
        Ok(response) => match serde_json::to_string(&response) {
            Ok(payload) => Ok((ok(), payload)),
            Err(reason) => {
                let err = NativeError::new(
                    "native_error",
                    "failed to serialize native success response",
                    json!({"reason": reason.to_string()}),
                );
                Ok((error(), err.encode()))
            }
        },
        Err(native_error) => Ok((error(), native_error.encode())),
    }
}

async fn read_body_with_limit(
    response: &mut wreq::Response,
    max_size: Option<u64>,
) -> Result<Vec<u8>, NativeError> {
    let limit = max_size.unwrap_or(u64::MAX) as usize;
    let mut body = Vec::new();

    while let Some(chunk) = response.chunk().await.map_err(|reason| {
        // reason = Display (user-friendly message), debug = Debug (inner error chain for diagnostics)
        NativeError::new(
            "transport_error",
            "failed to read response body",
            json!({"reason": reason.to_string(), "debug": format!("{reason:?}")}),
        )
    })? {
        if body.len() + chunk.len() > limit {
            return Err(NativeError::new(
                "invalid_request",
                "response body exceeds max_body_size",
                json!({"limit": limit}),
            ));
        }
        body.extend_from_slice(&chunk);
    }

    Ok(body)
}

fn execute_request(request: NativeRequest) -> Result<NativeResponse, NativeError> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|reason| {
            NativeError::new(
                "runtime_error",
                "failed to initialize tokio runtime",
                json!({"reason": reason.to_string()}),
            )
        })?;

    runtime.block_on(async move {
        let mut client_builder = Client::builder();

        if let Some(profile_name) = request.emulation.as_deref() {
            let profile: Emulation =
                serde_json::from_value(Value::String(profile_name.to_string())).map_err(
                    |reason| {
                        NativeError::new(
                            "invalid_request",
                            "unknown emulation profile",
                            json!({"reason": reason.to_string(), "value": profile_name}),
                        )
                    },
                )?;

            client_builder = client_builder.emulation(profile);
        }

        if request.insecure_skip_verify {
            client_builder = client_builder.cert_verification(false);
        }

        let client = client_builder.build().map_err(|reason| {
            NativeError::new(
                "transport_error",
                "failed to build HTTP client",
                json!({"reason": reason.to_string(), "debug": format!("{reason:?}")}),
            )
        })?;

        let method = Method::from_bytes(request.method.as_bytes()).map_err(|reason| {
            NativeError::new(
                "invalid_request",
                "invalid HTTP method",
                json!({"reason": reason.to_string(), "value": request.method}),
            )
        })?;

        let mut builder = client
            .request(method, request.url.as_str())
            .timeout(Duration::from_millis(request.receive_timeout_ms));

        for [name, value] in request.headers {
            builder = builder.header(name.as_str(), value.as_str());
        }

        if let Some(body_base64) = request.body_base64 {
            let body = STANDARD.decode(body_base64.as_bytes()).map_err(|reason| {
                NativeError::new(
                    "invalid_request",
                    "body_base64 must be valid base64",
                    json!({"reason": reason.to_string()}),
                )
            })?;

            builder = builder.body(body);
        }

        let mut response = builder.send().await.map_err(|reason| {
            NativeError::new(
                "transport_error",
                "request execution failed",
                json!({"reason": reason.to_string(), "debug": format!("{reason:?}")}),
            )
        })?;

        let status = response.status().as_u16();
        let url = response.uri().to_string();
        let headers = response
            .headers()
            .iter()
            .map(|(name, value)| {
                [
                    name.to_string(),
                    String::from_utf8_lossy(value.as_bytes()).into_owned(),
                ]
            })
            .collect::<Vec<_>>();

        let body_bytes =
            read_body_with_limit(&mut response, request.max_body_size_bytes).await?;

        Ok(NativeResponse {
            status,
            url,
            headers,
            body_base64: STANDARD.encode(body_bytes),
        })
    })
}

rustler::init!("Elixir.CloakedReq.Native");

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc;
    use std::thread;
    use std::time::Duration as StdDuration;

    fn spawn_test_server(
        response_bytes: Vec<u8>,
        read_timeout_ms: u64,
    ) -> (String, mpsc::Receiver<Vec<u8>>, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener must bind");
        let addr = listener.local_addr().expect("local addr must be available");
        let (tx, rx) = mpsc::channel::<Vec<u8>>();

        let handle = thread::spawn(move || {
            let (mut stream, _) = listener
                .accept()
                .expect("server must accept one connection");
            stream
                .set_read_timeout(Some(StdDuration::from_millis(read_timeout_ms)))
                .expect("read timeout should be set");

            let mut request = Vec::new();
            let mut buffer = [0_u8; 2048];

            loop {
                match stream.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(bytes) => request.extend_from_slice(&buffer[..bytes]),
                    Err(error)
                        if error.kind() == std::io::ErrorKind::WouldBlock
                            || error.kind() == std::io::ErrorKind::TimedOut =>
                    {
                        break;
                    }
                    Err(error) => panic!("server read failed: {error}"),
                }
            }

            tx.send(request).expect("request payload should be sent");
            stream
                .write_all(&response_bytes)
                .expect("response should be written");
            stream.flush().expect("response should flush");
        });

        (format!("http://{addr}/"), rx, handle)
    }

    fn base_request() -> NativeRequest {
        NativeRequest {
            method: "GET".to_string(),
            url: "http://example.com".to_string(),
            headers: vec![],
            body_base64: None,
            receive_timeout_ms: 5_000,
            emulation: None,
            insecure_skip_verify: false,
            max_body_size_bytes: None,
        }
    }

    #[test]
    fn rejects_unknown_emulation_profile() {
        let mut request = base_request();
        request.emulation = Some("unknown_browser".to_string());

        let result = execute_request(request);
        assert!(result.is_err());

        let err = result.err().expect("expected error");
        assert_eq!(err.type_name, "invalid_request");
        assert_eq!(err.message, "unknown emulation profile");
    }

    #[test]
    fn rejects_invalid_body_base64() {
        let mut request = base_request();
        request.body_base64 = Some("###not-base64###".to_string());

        let result = execute_request(request);
        assert!(result.is_err());

        let err = result.err().expect("expected error");
        assert_eq!(err.type_name, "invalid_request");
        assert_eq!(err.message, "body_base64 must be valid base64");
    }

    #[test]
    fn rejects_invalid_http_method() {
        let mut request = base_request();
        request.method = "BAD METHOD".to_string();

        let result = execute_request(request);
        assert!(result.is_err());

        let err = result.err().expect("expected error");
        assert_eq!(err.type_name, "invalid_request");
        assert_eq!(err.message, "invalid HTTP method");
    }

    #[test]
    fn executes_local_http_request_successfully() {
        let response_body = "ok";
        let raw_response = format!(
            "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
            response_body.len(),
            response_body
        )
        .into_bytes();
        let (url, received_request, server) = spawn_test_server(raw_response, 200);

        let mut request = base_request();
        request.url = url;
        request.headers = vec![["x-demo".to_string(), "1".to_string()]];

        let response = execute_request(request).expect("request should succeed");
        server.join().expect("server thread must join");

        assert_eq!(response.status, 200);
        let body = STANDARD
            .decode(response.body_base64.as_bytes())
            .expect("body should decode");
        assert_eq!(body, b"ok");
        assert!(response
            .headers
            .iter()
            .any(|header| header[0].eq_ignore_ascii_case("content-type")
                && header[1].contains("text/plain")));

        let raw_request = received_request
            .recv_timeout(StdDuration::from_secs(1))
            .expect("must capture request");
        let request_text = String::from_utf8(raw_request).expect("request should be utf-8");
        assert!(request_text.starts_with("GET / HTTP/1.1"));
        assert!(request_text.contains("x-demo: 1"));
    }

    #[test]
    fn sends_body_to_local_http_server() {
        let response_body = "created";
        let raw_response = format!(
            "HTTP/1.1 201 Created\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
            response_body.len(),
            response_body
        )
        .into_bytes();
        let (url, received_request, server) = spawn_test_server(raw_response, 300);

        let mut request = base_request();
        request.method = "POST".to_string();
        request.url = url;
        request.body_base64 = Some(STANDARD.encode("hello"));

        let response = execute_request(request).expect("request should succeed");
        server.join().expect("server thread must join");

        assert_eq!(response.status, 201);
        let raw_request = received_request
            .recv_timeout(StdDuration::from_secs(1))
            .expect("must capture request");
        let request_text = String::from_utf8(raw_request).expect("request should be utf-8");
        assert!(request_text.starts_with("POST / HTTP/1.1"));
        assert!(request_text.contains("hello"));
    }

    #[test]
    fn returns_transport_error_on_receive_timeout() {
        let (url, _received_request, server) = {
            let listener = TcpListener::bind("127.0.0.1:0").expect("listener must bind");
            let addr = listener.local_addr().expect("local addr");
            let (tx, rx) = mpsc::channel::<Vec<u8>>();

            let handle = thread::spawn(move || {
                let (mut stream, _) = listener.accept().expect("server must accept");
                stream
                    .set_read_timeout(Some(StdDuration::from_millis(100)))
                    .expect("read timeout should be set");
                let mut request = Vec::new();
                let mut buffer = [0_u8; 1024];
                let _ = stream.read(&mut buffer).map(|bytes| {
                    request.extend_from_slice(&buffer[..bytes]);
                });
                tx.send(request).expect("request should be sent");
                thread::sleep(StdDuration::from_millis(350));
                let _ = stream.write_all(
                    b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok",
                );
                let _ = stream.flush();
            });

            (format!("http://{addr}/"), rx, handle)
        };

        let mut request = base_request();
        request.url = url;
        request.receive_timeout_ms = 50;

        let result = execute_request(request);
        server.join().expect("server thread must join");
        assert!(result.is_err());
        let error = result.err().expect("expected error");
        assert_eq!(error.type_name, "transport_error");
        assert_eq!(error.message, "request execution failed");
    }

    #[test]
    fn fingerprint_smoke_test_with_emulation() {
        let mut last_error: Option<NativeError> = None;

        for attempt in 1..=3 {
            let request = NativeRequest {
                method: "GET".to_string(),
                url: "https://tls.peet.ws/api/all".to_string(),
                headers: vec![],
                body_base64: None,
                receive_timeout_ms: 20_000,
                emulation: Some("chrome_136".to_string()),
                insecure_skip_verify: true,
                max_body_size_bytes: None,
            };

            match execute_request(request) {
                Ok(response) => {
                    if response.status >= 200 && response.status < 300 {
                        let decoded = STANDARD
                            .decode(response.body_base64.as_bytes())
                            .expect("response body must be base64");
                        let payload: serde_json::Value =
                            serde_json::from_slice(&decoded).expect("response body must be JSON");

                        let has_ja4 = payload
                            .as_object()
                            .map(|map| {
                                map.contains_key("ja4") || map.keys().any(|key| key.starts_with("ja4"))
                            })
                            .unwrap_or(false);

                        assert!(has_ja4);
                        return;
                    }

                    assert!(response.status >= 500);
                    return;
                }
                Err(error) => {
                    last_error = Some(error);
                    if attempt < 3 {
                        thread::sleep(StdDuration::from_millis(500 * attempt));
                    }
                }
            }
        }

        let error = last_error.expect("last error must be present after retries");
        panic!(
            "fingerprint request failed after retries: {}: {}",
            error.type_name, error.message
        );
    }

    #[test]
    fn rejects_response_body_exceeding_max_body_size() {
        let body = "x".repeat(200);
        let raw_response = format!(
            "HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
            body.len(),
            body
        )
        .into_bytes();
        let (url, _rx, server) = spawn_test_server(raw_response, 200);

        let mut request = base_request();
        request.url = url;
        request.max_body_size_bytes = Some(100);

        let result = execute_request(request);
        server.join().expect("server thread must join");

        assert!(result.is_err());
        let err = result.err().expect("expected error");
        assert_eq!(err.type_name, "invalid_request");
        assert_eq!(err.message, "response body exceeds max_body_size");
    }

    #[test]
    fn accepts_response_body_within_max_body_size() {
        let body = "ok";
        let raw_response = format!(
            "HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
            body.len(),
            body
        )
        .into_bytes();
        let (url, _rx, server) = spawn_test_server(raw_response, 200);

        let mut request = base_request();
        request.url = url;
        request.max_body_size_bytes = Some(1024);

        let response = execute_request(request).expect("request should succeed");
        server.join().expect("server thread must join");

        assert_eq!(response.status, 200);
        let decoded = STANDARD
            .decode(response.body_base64.as_bytes())
            .expect("body should decode");
        assert_eq!(decoded, b"ok");
    }

    #[test]
    fn handles_empty_response_body() {
        let raw_response =
            b"HTTP/1.1 204 No Content\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
                .to_vec();
        let (url, _rx, server) = spawn_test_server(raw_response, 200);

        let mut request = base_request();
        request.url = url;

        let response = execute_request(request).expect("request should succeed");
        server.join().expect("server thread must join");

        assert_eq!(response.status, 204);
        let decoded = STANDARD
            .decode(response.body_base64.as_bytes())
            .expect("body should decode");
        assert!(decoded.is_empty());
    }

    #[test]
    fn accepts_body_at_exact_max_body_size_boundary() {
        let body = "x".repeat(100);
        let raw_response = format!(
            "HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
            body.len(),
            body
        )
        .into_bytes();
        let (url, _rx, server) = spawn_test_server(raw_response, 200);

        let mut request = base_request();
        request.url = url;
        request.max_body_size_bytes = Some(100);

        let response = execute_request(request).expect("request at exact limit should succeed");
        server.join().expect("server thread must join");

        assert_eq!(response.status, 200);
        let decoded = STANDARD
            .decode(response.body_base64.as_bytes())
            .expect("body should decode");
        assert_eq!(decoded.len(), 100);
    }

    #[test]
    fn handles_non_utf8_header_values() {
        // Header value contains raw bytes that are not valid UTF-8.
        // wreq uses from_utf8_lossy, so we expect replacement characters.
        let mut raw_response = Vec::new();
        raw_response.extend_from_slice(b"HTTP/1.1 200 OK\r\nx-binary: ");
        raw_response.extend_from_slice(&[0xff, 0xfe]);
        raw_response.extend_from_slice(b"\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok");
        let (url, _rx, server) = spawn_test_server(raw_response, 200);

        let mut request = base_request();
        request.url = url;

        let result = execute_request(request);
        server.join().expect("server thread must join");

        // wreq may reject invalid header bytes at the HTTP parsing level.
        // Either a successful response with lossy-decoded headers or a transport error is acceptable.
        match result {
            Ok(response) => {
                assert_eq!(response.status, 200);
                let binary_header = response
                    .headers
                    .iter()
                    .find(|h| h[0] == "x-binary")
                    .expect("x-binary header should exist");
                // from_utf8_lossy replaces invalid bytes with U+FFFD
                assert!(binary_header[1].contains('\u{FFFD}'));
            }
            Err(err) => {
                // Acceptable: wreq rejects non-UTF8 headers at parse level
                assert_eq!(err.type_name, "transport_error");
            }
        }
    }

    #[test]
    fn panic_protection_converts_panic_to_nif_panic_error() {
        let result = run_with_panic_protection(|| {
            panic!("simulated NIF panic");
        });
        let err = result.unwrap_err();
        assert_eq!(err.type_name, "nif_panic");
        assert_eq!(err.message, "simulated NIF panic");
    }

    #[test]
    fn panic_protection_passes_through_ok() {
        let result = run_with_panic_protection(|| {
            Ok(NativeResponse {
                status: 200,
                url: "https://example.com".to_string(),
                headers: vec![],
                body_base64: "".to_string(),
            })
        });
        assert_eq!(result.unwrap().status, 200);
    }

    #[test]
    fn panic_protection_passes_through_err() {
        let result = run_with_panic_protection(|| {
            Err(NativeError::new("transport_error", "timeout", json!({})))
        });
        let err = result.unwrap_err();
        assert_eq!(err.type_name, "transport_error");
    }
}
