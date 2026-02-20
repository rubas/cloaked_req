mod error;
mod request;
mod response;

use std::collections::HashMap;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{LazyLock, RwLock};
use std::time::Duration;

use error::NativeError;
use request::NativeRequest;
use response::NativeResponseMeta;
use rustler::serde::SerdeTerm;
use rustler::types::binary::{Binary, NewBinary};
use rustler::{Encoder, Env, ResourceArc, Term};
use serde_json::{json, Value};
use wreq::cookie::{CookieStore, Cookies};
use wreq::{Client, Method};
use wreq_util::Emulation;

rustler::atoms! {
    ok,
    error
}

/// Shared tokio runtime for all NIF calls. Created once on first use.
static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("tokio runtime must initialize")
});

/// Cache key: (emulation profile, insecure_skip_verify).
type ClientKey = (Option<String>, bool);

/// Persistent client pool. Clients are reused across NIF calls for connection
/// pooling, TLS session resumption, and HTTP keep-alive.
static CLIENT_CACHE: LazyLock<RwLock<HashMap<ClientKey, Client>>> =
    LazyLock::new(|| RwLock::new(HashMap::new()));

/// Opaque cookie jar resource held by the BEAM.
///
/// Wraps wreq's `Jar` (RFC 6265-compliant cookie store). The jar is
/// automatically dropped when the Elixir term is garbage collected.
struct CookieJarResource {
    jar: wreq::cookie::Jar,
}

fn get_or_build_client(
    emulation: Option<&str>,
    insecure_skip_verify: bool,
) -> Result<Client, NativeError> {
    let key = (emulation.map(|s| s.to_string()), insecure_skip_verify);

    // Fast path: read lock
    {
        let cache = CLIENT_CACHE.read().unwrap_or_else(|e| e.into_inner());
        if let Some(client) = cache.get(&key) {
            return Ok(client.clone());
        }
    }

    // Slow path: write lock, double-check
    let mut cache = CLIENT_CACHE.write().unwrap_or_else(|e| e.into_inner());
    if let Some(client) = cache.get(&key) {
        return Ok(client.clone());
    }

    let mut builder = Client::builder()
        .pool_max_idle_per_host(20)
        .connect_timeout(Duration::from_secs(10));

    if let Some(profile_name) = emulation {
        let profile: Emulation = serde_json::from_value(Value::String(profile_name.to_string()))
            .map_err(|reason| {
                NativeError::new(
                    "invalid_request",
                    "unknown emulation profile",
                    json!({"reason": reason.to_string(), "value": profile_name}),
                )
            })?;

        builder = builder.emulation(profile);
    }

    if insecure_skip_verify {
        builder = builder.cert_verification(false);
    }

    let client = builder.build().map_err(|reason| {
        NativeError::new(
            "transport_error",
            "failed to build HTTP client",
            json!({"reason": reason.to_string(), "debug": format!("{reason:?}")}),
        )
    })?;

    cache.insert(key, client.clone());
    Ok(client)
}

fn run_with_panic_protection<T, F>(f: F) -> Result<T, NativeError>
where
    F: FnOnce() -> Result<T, NativeError>,
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

/// Creates a new empty cookie jar.
#[rustler::nif]
fn nif_create_cookie_jar() -> ResourceArc<CookieJarResource> {
    ResourceArc::new(CookieJarResource {
        jar: wreq::cookie::Jar::default(),
    })
}

/// NIF entry point. Receives a native Elixir map (decoded via NifMap) + optional raw body binary
/// + optional cookie jar resource.
/// Returns `{:ok, response_meta_map, body_binary}` or `{:error, error_map}`.
#[rustler::nif(schedule = "DirtyIo")]
fn nif_perform_request<'a>(
    env: Env<'a>,
    request: NativeRequest,
    body: Option<Binary>,
    cookie_jar: Option<ResourceArc<CookieJarResource>>,
) -> Term<'a> {
    let body_vec = body.map(|b| b.as_slice().to_vec());
    let result = run_with_panic_protection(|| execute_request(request, body_vec, cookie_jar));

    match result {
        Ok((meta, response_body)) => {
            let mut new_bin = NewBinary::new(env, response_body.len());
            new_bin.as_mut_slice().copy_from_slice(&response_body);
            let body_binary = Binary::from(new_bin);
            (ok(), meta, body_binary).encode(env)
        }
        Err(native_error) => {
            let error_value =
                serde_json::to_value(native_error).expect("NativeError must serialize");
            (error(), SerdeTerm(error_value)).encode(env)
        }
    }
}

async fn read_body_with_limit(
    response: &mut wreq::Response,
    max_size: Option<u64>,
) -> Result<Vec<u8>, NativeError> {
    let limit = max_size.unwrap_or(u64::MAX) as usize;

    let content_length = response
        .headers()
        .get("content-length")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<usize>().ok());

    let mut body = match content_length {
        Some(len) if len <= limit => Vec::with_capacity(len),
        _ => Vec::new(),
    };

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

fn execute_request(
    request: NativeRequest,
    body: Option<Vec<u8>>,
    cookie_jar: Option<ResourceArc<CookieJarResource>>,
) -> Result<(NativeResponseMeta, Vec<u8>), NativeError> {
    let client = get_or_build_client(request.emulation.as_deref(), request.insecure_skip_verify)?;

    RUNTIME.block_on(async move {
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

        // Iterate by reference so request.url remains accessible for cookie jar
        for (name, value) in &request.headers {
            builder = builder.header(name.as_str(), value.as_str());
        }

        // Add cookies from jar before sending
        if let Some(ref jar) = cookie_jar {
            if let Ok(parsed_uri) = request.url.parse::<http::Uri>() {
                match jar.jar.cookies(&parsed_uri) {
                    Cookies::Compressed(val) => {
                        builder = builder.header("cookie", val);
                    }
                    Cookies::Uncompressed(vals) => {
                        for val in vals {
                            builder = builder.header("cookie", val);
                        }
                    }
                    _ => {}
                }
            }
        }

        if let Some(body) = body {
            builder = builder.body(body);
        }

        let mut response = builder.send().await.map_err(|reason| {
            NativeError::new(
                "transport_error",
                "request execution failed",
                json!({"reason": reason.to_string(), "debug": format!("{reason:?}")}),
            )
        })?;

        // Store cookies from response into jar (with PSL validation)
        if let Some(ref jar) = cookie_jar {
            if let Ok(parsed_uri) = request.url.parse::<http::Uri>() {
                let host = parsed_uri.host().unwrap_or_default();
                let set_cookies: Vec<_> = response
                    .headers()
                    .get_all("set-cookie")
                    .iter()
                    .filter(|hv| is_cookie_domain_safe(hv.as_bytes(), host))
                    .collect();
                if !set_cookies.is_empty() {
                    let mut iter = set_cookies.into_iter();
                    jar.jar.set_cookies(&mut iter, &parsed_uri);
                }
            }
        }

        let status = response.status().as_u16();
        let url = response.uri().to_string();
        let headers = response
            .headers()
            .iter()
            .map(|(name, value)| {
                (
                    name.to_string(),
                    String::from_utf8_lossy(value.as_bytes()).into_owned(),
                )
            })
            .collect::<Vec<_>>();

        let body_bytes = read_body_with_limit(&mut response, request.max_body_size_bytes).await?;

        Ok((
            NativeResponseMeta {
                status,
                url,
                headers,
            },
            body_bytes,
        ))
    })
}

/// Validates that a `set-cookie` header's Domain attribute is safe to store.
///
/// Rejects cookies whose Domain is a public suffix (e.g. "com", "co.uk",
/// "github.io") or doesn't match the request host at a label boundary.
/// Host-only cookies (no Domain attribute) are always accepted.
fn is_cookie_domain_safe(header_bytes: &[u8], request_host: &str) -> bool {
    let header_str = match std::str::from_utf8(header_bytes) {
        Ok(s) => s,
        Err(_) => return false,
    };

    let domain = match extract_cookie_domain(header_str) {
        Some(d) => d,
        None => return true, // No Domain attr → host-only cookie, always safe
    };

    let effective_domain = domain.trim_start_matches('.').to_lowercase();

    // Reject if the domain is a public suffix (no registrable domain above it)
    if psl::domain(effective_domain.as_bytes()).is_none() {
        return false;
    }

    // Verify origin: Domain must match request host at label boundary
    let host = request_host.to_lowercase();

    host == effective_domain
        || (host.len() > effective_domain.len()
            && host.ends_with(&effective_domain)
            && host.as_bytes()[host.len() - effective_domain.len() - 1] == b'.')
}

/// Extracts the Domain attribute value from a set-cookie header string.
fn extract_cookie_domain(header: &str) -> Option<&str> {
    header
        .split(';')
        .skip(1) // skip name=value
        .find_map(|attr| {
            let attr = attr.trim();
            if attr.len() > 7 && attr[..7].eq_ignore_ascii_case("domain=") {
                Some(attr[7..].trim())
            } else {
                None
            }
        })
}

fn on_load(env: Env, _info: Term) -> bool {
    let _ = rustler::resource!(CookieJarResource, env);
    true
}

rustler::init!("Elixir.CloakedReq.Native", load = on_load);

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

        let result = execute_request(request, None, None);
        assert!(result.is_err());

        let err = result.err().expect("expected error");
        assert_eq!(err.type_name, "invalid_request");
        assert_eq!(err.message, "unknown emulation profile");
    }

    #[test]
    fn rejects_invalid_http_method() {
        let mut request = base_request();
        request.method = "BAD METHOD".to_string();

        let result = execute_request(request, None, None);
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
        request.headers = vec![("x-demo".to_string(), "1".to_string())];

        let (meta, body) = execute_request(request, None, None).expect("request should succeed");
        server.join().expect("server thread must join");

        assert_eq!(meta.status, 200);
        assert_eq!(body, b"ok");
        assert!(meta
            .headers
            .iter()
            .any(|header| header.0.eq_ignore_ascii_case("content-type")
                && header.1.contains("text/plain")));

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

        let (meta, _body) = execute_request(request, Some(b"hello".to_vec()), None)
            .expect("request should succeed");
        server.join().expect("server thread must join");

        assert_eq!(meta.status, 201);
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

        let result = execute_request(request, None, None);
        server.join().expect("server thread must join");
        assert!(result.is_err());
        let error = result.err().expect("expected error");
        assert_eq!(error.type_name, "transport_error");
        assert_eq!(error.message, "request execution failed");
    }

    #[test]
    fn fingerprint_smoke_test_with_emulation() {
        let request = NativeRequest {
            method: "GET".to_string(),
            url: "https://tlsinfo.me/json".to_string(),
            headers: vec![],
            receive_timeout_ms: 20_000,
            emulation: Some("chrome_136".to_string()),
            insecure_skip_verify: false,
            max_body_size_bytes: None,
        };

        let (meta, body) =
            execute_request(request, None, None).expect("fingerprint request should succeed");
        assert!(meta.status >= 200 && meta.status < 300);

        let payload: serde_json::Value =
            serde_json::from_slice(&body).expect("response body must be JSON");

        assert!(payload.get("ja4").and_then(|v| v.as_str()).is_some());
        assert!(payload.get("ja3").and_then(|v| v.as_str()).is_some());
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

        let result = execute_request(request, None, None);
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

        let (meta, response_body) =
            execute_request(request, None, None).expect("request should succeed");
        server.join().expect("server thread must join");

        assert_eq!(meta.status, 200);
        assert_eq!(response_body, b"ok");
    }

    #[test]
    fn handles_empty_response_body() {
        let raw_response =
            b"HTTP/1.1 204 No Content\r\ncontent-length: 0\r\nconnection: close\r\n\r\n".to_vec();
        let (url, _rx, server) = spawn_test_server(raw_response, 200);

        let mut request = base_request();
        request.url = url;

        let (meta, body) = execute_request(request, None, None).expect("request should succeed");
        server.join().expect("server thread must join");

        assert_eq!(meta.status, 204);
        assert!(body.is_empty());
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

        let (meta, response_body) =
            execute_request(request, None, None).expect("request at exact limit should succeed");
        server.join().expect("server thread must join");

        assert_eq!(meta.status, 200);
        assert_eq!(response_body.len(), 100);
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

        let result = execute_request(request, None, None);
        server.join().expect("server thread must join");

        // wreq may reject invalid header bytes at the HTTP parsing level.
        // Either a successful response with lossy-decoded headers or a transport error is acceptable.
        match result {
            Ok((meta, _body)) => {
                assert_eq!(meta.status, 200);
                let binary_header = meta
                    .headers
                    .iter()
                    .find(|h| h.0 == "x-binary")
                    .expect("x-binary header should exist");
                // from_utf8_lossy replaces invalid bytes with U+FFFD
                assert!(binary_header.1.contains('\u{FFFD}'));
            }
            Err(err) => {
                // Acceptable: wreq rejects non-UTF8 headers at parse level
                assert_eq!(err.type_name, "transport_error");
            }
        }
    }

    #[test]
    fn panic_protection_converts_panic_to_nif_panic_error() {
        let result = run_with_panic_protection::<(), _>(|| {
            panic!("simulated NIF panic");
        });
        let err = result.unwrap_err();
        assert_eq!(err.type_name, "nif_panic");
        assert_eq!(err.message, "simulated NIF panic");
    }

    #[test]
    fn panic_protection_passes_through_ok() {
        let result = run_with_panic_protection(|| {
            Ok((
                NativeResponseMeta {
                    status: 200,
                    url: "https://example.com".to_string(),
                    headers: vec![],
                },
                Vec::<u8>::new(),
            ))
        });
        let (meta, body) = result.unwrap();
        assert_eq!(meta.status, 200);
        assert!(body.is_empty());
    }

    #[test]
    fn panic_protection_passes_through_err() {
        let result = run_with_panic_protection::<(), _>(|| {
            Err(NativeError::new("transport_error", "timeout", json!({})))
        });
        let err = result.unwrap_err();
        assert_eq!(err.type_name, "transport_error");
    }

    // --- Cookie domain safety tests ---

    #[test]
    fn psl_rejects_public_suffix_domain() {
        assert!(!is_cookie_domain_safe(b"evil=1; Domain=com", "example.com"));
        assert!(!is_cookie_domain_safe(
            b"evil=1; Domain=co.uk",
            "example.com"
        ));
    }

    #[test]
    fn psl_rejects_cross_origin_domain() {
        assert!(!is_cookie_domain_safe(b"x=1; Domain=other.com", "evil.com"));
    }

    #[test]
    fn psl_accepts_valid_parent_domain() {
        assert!(is_cookie_domain_safe(
            b"x=1; Domain=example.com",
            "sub.example.com"
        ));
    }

    #[test]
    fn psl_accepts_exact_host_domain() {
        assert!(is_cookie_domain_safe(
            b"x=1; Domain=example.com",
            "example.com"
        ));
    }

    #[test]
    fn psl_accepts_host_only_cookie() {
        assert!(is_cookie_domain_safe(b"session=abc; Path=/", "example.com"));
    }

    #[test]
    fn psl_rejects_non_label_boundary_match() {
        assert!(!is_cookie_domain_safe(
            b"x=1; Domain=example.com",
            "notexample.com"
        ));
    }

    #[test]
    fn extract_cookie_domain_parses_correctly() {
        assert_eq!(
            extract_cookie_domain("session=abc; Domain=.example.com; Path=/"),
            Some(".example.com")
        );
        assert_eq!(extract_cookie_domain("session=abc; Path=/"), None);
        assert_eq!(
            extract_cookie_domain("session=abc; path=/; domain=test.com; secure"),
            Some("test.com")
        );
    }

    #[test]
    fn psl_rejects_non_utf8_header() {
        assert!(!is_cookie_domain_safe(&[0xff, 0xfe], "example.com"));
    }
}
