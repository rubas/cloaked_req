mod error;
mod request;
mod response;

use std::any::Any;
use std::num::NonZeroUsize;
use std::panic::AssertUnwindSafe;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use bytes::Bytes;
use cookie::Cookie;
use error::NativeError;
use futures_util::future::{AbortHandle, Abortable};
use futures_util::{FutureExt, StreamExt};
use lru::LruCache;
use request::{NativePoolConfig, NativeProxyConfig, NativeRequest};
use response::{NativeResponseMeta, RawHeaderValue};
use rustler::types::binary::{Binary, NewBinary};
use rustler::{Encoder, Env, LocalPid, Monitor, OwnedEnv, ResourceArc, Term};
use serde_json::{Value, json};
use wreq::cookie::{CookieStore, Cookies, Jar};
use wreq::header::{HeaderMap, HeaderName, HeaderValue};
use wreq::{Client, Method, Proxy, Uri, Version};
use wreq_util::Profile;

rustler::atoms! {
    ok,
    error,
    cloaked_req_response
}

static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("tokio runtime must initialize")
});

/// Cache key for a built `Client`. Proxy and source IP are applied per request
/// (wreq's connection pool keys on both, so connections are never shared across
/// them), so they stay out of the key. What remains is bounded by an LRU because
/// `connect_timeout_ms` is caller-controlled.
type ClientKey = (Option<String>, bool, u64);

const CLIENT_CACHE_CAP: usize = 128;

static CLIENT_CACHE: LazyLock<Mutex<LruCache<ClientKey, Client>>> = LazyLock::new(|| {
    Mutex::new(LruCache::new(
        NonZeroUsize::new(CLIENT_CACHE_CAP).expect("client cache capacity is non-zero"),
    ))
});

/// Opaque cookie jar resource held by the BEAM.
///
/// Wraps wreq's `Jar` (RFC 6265-compliant cookie store). The jar is
/// automatically dropped when the Elixir term is garbage collected.
struct CookieJarResource {
    store: Arc<PublicSuffixGuard>,
}

impl rustler::Resource for CookieJarResource {}

/// Adds the one check `Jar` lacks, the public suffix check in `cookie_for_jar`.
struct PublicSuffixGuard(Jar);

impl CookieStore for PublicSuffixGuard {
    fn set_cookies(&self, cookie_headers: &mut dyn Iterator<Item = &HeaderValue>, uri: &Uri) {
        for header in cookie_headers {
            if let Some(cookie) = cookie_for_jar(header.as_bytes(), uri.host()) {
                self.0.add(cookie, uri);
            }
        }
    }

    fn cookies(&self, uri: &Uri, version: Version) -> Cookies {
        self.0.cookies(uri, version)
    }
}

/// Opaque HTTP client resource held by the BEAM.
///
/// Wraps a fully built wreq `Client` with its own connection pool. The client
/// is automatically dropped when the Elixir term is garbage collected.
struct ClientResource {
    client: Client,
}

impl rustler::Resource for ClientResource {}

/// Aborts the request task when the calling process dies.
struct RequestCancellationResource(AbortHandle);

impl rustler::Resource for RequestCancellationResource {
    const IMPLEMENTS_DOWN: bool = true;

    fn down<'a>(&'a self, _env: Env<'a>, _pid: LocalPid, _monitor: Monitor) {
        self.0.abort();
    }
}

fn get_or_build_client(
    emulation: Option<&str>,
    insecure_skip_verify: bool,
    connect_timeout_ms: u64,
) -> Result<Client, NativeError> {
    let key = (
        emulation.map(|s| s.to_string()),
        insecure_skip_verify,
        connect_timeout_ms,
    );

    {
        let mut cache = CLIENT_CACHE.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(client) = cache.get(&key) {
            return Ok(client.clone());
        }
    }

    // Build with no lock held so a slow Client::build() never blocks other
    // cache users. A racing duplicate build is harmless: the loser is dropped.
    let client = build_client(emulation, insecure_skip_verify, connect_timeout_ms, None)?;

    let mut cache = CLIENT_CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(existing) = cache.get(&key) {
        return Ok(existing.clone());
    }
    cache.put(key, client.clone());
    Ok(client)
}

fn build_client(
    emulation: Option<&str>,
    insecure_skip_verify: bool,
    connect_timeout_ms: u64,
    pool_idle_timeout_ms: Option<u64>,
) -> Result<Client, NativeError> {
    let mut builder = Client::builder()
        .pool_max_idle_per_host(20)
        .connect_timeout(Duration::from_millis(connect_timeout_ms));

    if let Some(ms) = pool_idle_timeout_ms {
        builder = builder.pool_idle_timeout(Some(Duration::from_millis(ms)));
    }

    if let Some(profile_name) = emulation {
        let profile: Profile = serde_json::from_value(Value::String(profile_name.to_string()))
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
        builder = builder.tls_cert_verification(false);
    }

    builder.build().map_err(|reason| {
        NativeError::new(
            "transport_error",
            "failed to build HTTP client",
            json!({"reason": reason.to_string(), "debug": format!("{reason:?}")}),
        )
    })
}

fn build_proxy(proxy_config: &NativeProxyConfig) -> Result<Proxy, NativeError> {
    let mut proxy = Proxy::all(proxy_config.url.as_str()).map_err(|reason| {
        NativeError::new(
            "invalid_request",
            "invalid proxy URL",
            json!({"reason": reason.to_string(), "url": &proxy_config.url}),
        )
    })?;

    if !proxy_config.headers.is_empty() {
        let mut headers = HeaderMap::new();

        for (name, value) in &proxy_config.headers {
            let header_name = HeaderName::from_bytes(name.as_bytes()).map_err(|reason| {
                NativeError::new(
                    "invalid_request",
                    "invalid proxy header name",
                    json!({"reason": reason.to_string(), "name": name}),
                )
            })?;
            let header_value = HeaderValue::from_str(value).map_err(|reason| {
                NativeError::new(
                    "invalid_request",
                    "invalid proxy header value",
                    json!({"reason": reason.to_string(), "name": name}),
                )
            })?;

            headers.append(header_name, header_value);
        }

        proxy = proxy.custom_http_headers(headers);
    }

    Ok(proxy)
}

/// Creates a new empty cookie jar.
#[rustler::nif]
fn nif_create_cookie_jar() -> ResourceArc<CookieJarResource> {
    ResourceArc::new(CookieJarResource {
        store: Arc::new(PublicSuffixGuard(Jar::default())),
    })
}

/// Builds a dedicated HTTP client with its own connection pool.
#[rustler::nif(schedule = "DirtyCpu")]
fn nif_new_pool<'a>(env: Env<'a>, config: NativePoolConfig) -> Term<'a> {
    build_client(
        config.emulation.as_deref(),
        config.insecure_skip_verify,
        config.connect_timeout_ms,
        config.pool_idle_timeout_ms,
    )
    .map(|client| ResourceArc::new(ClientResource { client }))
    .encode(env)
}

#[rustler::nif]
fn nif_perform_request<'a>(
    env: Env<'a>,
    request: NativeRequest,
    body: Option<Binary>,
    token: Term<'a>,
    cookie_jar: Option<ResourceArc<CookieJarResource>>,
    pool: Option<ResourceArc<ClientResource>>,
) -> Term<'a> {
    let caller = env.pid();
    let mut token_env = OwnedEnv::new();
    let saved_token = token_env.save(token);
    // Save the body term rather than copying its bytes here: for a refcounted
    // binary `save` (enif_make_copy) only bumps the reference count, so the
    // scheduler thread does O(1) work regardless of body size. The actual copy
    // into an owned Vec happens on the Tokio thread below.
    let saved_body = body.map(|b| token_env.save(b));
    let (abort_handle, abort_registration) = AbortHandle::new_pair();
    let cancellation = ResourceArc::new(RequestCancellationResource(abort_handle));
    let monitor = env.monitor(&cancellation, &caller);

    // Every path replies except an abort, which only a dead caller triggers.
    // Panics are caught here, so the caller waits without a timeout.
    let task = async move {
        // A `&mut` borrow keeps the future Send: OwnedEnv is Send, not Sync.
        let body_env = &mut token_env;
        let result = AssertUnwindSafe(async move {
            let body = saved_body.map(|saved| {
                body_env.run(|env| {
                    saved
                        .load(env)
                        .decode::<Binary>()
                        .expect("request body was saved as a binary")
                        .as_slice()
                        .to_vec()
                })
            });
            execute_request_async(request, body, cookie_jar, pool).await
        })
        .catch_unwind()
        .await
        .unwrap_or_else(|payload| Err(panic_error(&*payload)));

        if let Some(monitor) = monitor {
            token_env.demonitor(&cancellation, &monitor);
        }

        let mut reply = |result| {
            token_env.send_and_clear(&caller, |env| {
                let token = saved_token.load(env);
                (
                    cloaked_req_response(),
                    token,
                    encode_request_result(env, result),
                )
            })
        };

        // A panic while encoding, such as a failed allocation for a large body,
        // leaves the env uncleared, so the token still loads for a short reply.
        if let Err(payload) = std::panic::catch_unwind(AssertUnwindSafe(|| reply(result))) {
            let _ = reply(Err(panic_error(&*payload)));
        }
    };

    RUNTIME.spawn(Abortable::new(task, abort_registration));

    ok().encode(env)
}

fn panic_error(payload: &(dyn Any + Send)) -> NativeError {
    let reason = payload
        .downcast_ref::<&str>()
        .copied()
        .or_else(|| payload.downcast_ref::<String>().map(String::as_str))
        .unwrap_or_default();
    NativeError::new(
        "nif_panic",
        "request task panicked",
        json!({"reason": reason}),
    )
}

fn encode_request_result<'a>(
    env: Env<'a>,
    result: Result<(NativeResponseMeta, Vec<Bytes>), NativeError>,
) -> Term<'a> {
    match result {
        Ok((meta, chunks)) => {
            let mut body = NewBinary::new(env, chunks.iter().map(Bytes::len).sum());
            let mut offset = 0;
            for chunk in chunks {
                body.as_mut_slice()[offset..offset + chunk.len()].copy_from_slice(&chunk);
                offset += chunk.len();
            }
            (ok(), meta, Binary::from(body)).encode(env)
        }
        Err(native_error) => (error(), native_error).encode(env),
    }
}

/// Keeps the refcounted chunks wreq yields, so the copy into the BEAM binary
/// is the only copy of the body.
async fn read_body_with_limit(
    response: wreq::Response,
    max_size: Option<u64>,
) -> Result<Vec<Bytes>, NativeError> {
    let limit = max_size.unwrap_or(u64::MAX) as usize;
    let mut size = 0;
    let mut chunks = Vec::new();
    let mut stream = response.bytes_stream();

    while let Some(chunk) = stream
        .next()
        .await
        .transpose()
        .map_err(|reason| transport_error("failed to read response body", &reason))?
    {
        size += chunk.len();
        if size > limit {
            return Err(NativeError::new(
                "invalid_request",
                "response body exceeds max_body_size",
                json!({"limit": limit}),
            ));
        }
        chunks.push(chunk);
    }

    Ok(chunks)
}

async fn execute_request_async(
    request: NativeRequest,
    body: Option<Vec<u8>>,
    cookie_jar: Option<ResourceArc<CookieJarResource>>,
    pool: Option<ResourceArc<ClientResource>>,
) -> Result<(NativeResponseMeta, Vec<Bytes>), NativeError> {
    let client = match &pool {
        Some(p) => p.client.clone(),
        None => get_or_build_client(
            request.emulation.as_deref(),
            request.insecure_skip_verify,
            request.connect_timeout_ms,
        )?,
    };

    let method = Method::from_bytes(request.method.as_bytes()).map_err(|reason| {
        NativeError::new(
            "invalid_request",
            "invalid HTTP method",
            json!({"reason": reason.to_string(), "value": request.method}),
        )
    })?;

    // Req's :receive_timeout. README.md states what it bounds.
    let mut builder = client
        .request(method, request.url.as_str())
        .read_timeout(Duration::from_millis(request.receive_timeout_ms));

    // Proxy and source IP are per-request: wreq's connection pool keys on both,
    // so the shared client never reuses a connection across proxies or source
    // IPs, and the client cache stays bounded under proxy/IP rotation.
    if let Some(ref proxy_config) = request.proxy {
        builder = builder.proxy(build_proxy(proxy_config)?);
    }

    if let Some(ref addr_str) = request.local_address {
        let addr: std::net::IpAddr = addr_str.parse().map_err(|_| {
            NativeError::new(
                "invalid_request",
                "invalid local_address",
                json!({"value": addr_str}),
            )
        })?;
        builder = builder.local_address(addr);
    }

    for (name, value) in &request.headers {
        builder = builder.header(name.as_str(), value.as_str());
    }

    // wreq skips the jar when the caller set a Cookie header, and stores each
    // set-cookie against the URI it sent the request to.
    if let Some(jar) = cookie_jar {
        builder = builder.cookie_provider(jar.store.clone());
    }

    if let Some(body) = body {
        builder = builder.body(body);
    }

    let response = builder.send().await.map_err(|reason| {
        if reason.is_builder() {
            NativeError::new(
                "invalid_request",
                "invalid request",
                json!({"reason": reason.to_string()}),
            )
        } else {
            transport_error("request execution failed", &reason)
        }
    })?;

    let status = response.status().as_u16();
    let headers = response
        .headers()
        .iter()
        .map(|(name, value)| (name.as_str().to_owned(), RawHeaderValue(value.clone())))
        .collect::<Vec<_>>();

    let body_bytes = read_body_with_limit(response, request.max_body_size_bytes).await?;

    Ok((NativeResponseMeta { status, headers }, body_bytes))
}

#[cfg(test)]
fn execute_request(
    request: NativeRequest,
    body: Option<Vec<u8>>,
    cookie_jar: Option<ResourceArc<CookieJarResource>>,
    pool: Option<ResourceArc<ClientResource>>,
) -> Result<(NativeResponseMeta, Vec<u8>), NativeError> {
    RUNTIME
        .block_on(execute_request_async(request, body, cookie_jar, pool))
        .map(|(meta, chunks)| (meta, chunks.concat()))
}

fn transport_error(message: &'static str, reason: &wreq::Error) -> NativeError {
    let mut details = json!({"reason": reason.to_string(), "debug": format!("{reason:?}")});
    if let Some(kind) = transport_error_kind(reason) {
        details["kind"] = json!(kind);
    }
    NativeError::new("transport_error", message, details)
}

/// Names the failure classes Req retries under `retry: :safe_transient`:
/// `timeout`, `econnrefused` and `closed`, the reasons `Req.TransportError`
/// carries for the Finch adapter. Anything else stays unclassified.
fn transport_error_kind(error: &wreq::Error) -> Option<&'static str> {
    use std::io::ErrorKind;

    if error.is_timeout() {
        return Some("timeout");
    }

    let mut source = std::error::Error::source(error);
    while let Some(err) = source {
        if let Some(proto) = err.downcast_ref::<wreq_proto::Error>()
            && (proto.is_incomplete_message() || proto.is_closed())
        {
            return Some("closed");
        }
        if let Some(io) = err.downcast_ref::<std::io::Error>() {
            match io.kind() {
                ErrorKind::ConnectionRefused => return Some("econnrefused"),
                ErrorKind::ConnectionReset
                | ErrorKind::ConnectionAborted
                | ErrorKind::BrokenPipe
                | ErrorKind::UnexpectedEof => return Some("closed"),
                _ => {}
            }
        }
        source = err.source();
    }

    None
}

/// Parses a `set-cookie` header with the parser the jar uses, so the check
/// sees the Domain the jar stores. A Domain that is a public suffix (e.g.
/// "com", "co.uk", "github.io") drops the cookie, unless it equals the request
/// host, such as `localhost`: RFC 6265 section 5.3 step 5 then makes the
/// cookie host-only. The jar rejects a Domain that does not match the host.
fn cookie_for_jar<'a>(header: &'a [u8], host: Option<&str>) -> Option<Cookie<'a>> {
    let mut cookie = Cookie::parse(std::str::from_utf8(header).ok()?).ok()?;

    if let Some(domain) = cookie.domain().map(str::to_lowercase)
        && psl::domain(domain.as_bytes()).is_none()
    {
        if !host.is_some_and(|host| host.eq_ignore_ascii_case(&domain)) {
            return None;
        }
        cookie.unset_domain();
    }

    Some(cookie)
}

fn on_load(env: Env, _info: Term) -> bool {
    env.register::<CookieJarResource>().is_ok()
        && env.register::<RequestCancellationResource>().is_ok()
        && env.register::<ClientResource>().is_ok()
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
            connect_timeout_ms: 30_000,
            proxy: None,
            emulation: None,
            insecure_skip_verify: false,
            max_body_size_bytes: None,
            local_address: None,
        }
    }

    #[test]
    fn rejects_unknown_emulation_profile() {
        let mut request = base_request();
        request.emulation = Some("unknown_browser".to_string());

        let result = execute_request(request, None, None, None);
        let err = result.expect_err("expected error");
        assert_eq!(err.type_name, "invalid_request");
        assert_eq!(err.message, "unknown emulation profile");
    }

    #[test]
    fn rejects_invalid_http_method() {
        let mut request = base_request();
        request.method = "BAD METHOD".to_string();

        let result = execute_request(request, None, None, None);
        let err = result.expect_err("expected error");
        assert_eq!(err.type_name, "invalid_request");
        assert_eq!(err.message, "invalid HTTP method");
    }

    #[test]
    fn rejects_invalid_header_value_as_invalid_request() {
        let mut request = base_request();
        request.headers = vec![("x-bad".to_string(), "a\nb".to_string())];

        let err = execute_request(request, None, None, None).expect_err("expected error");
        assert_eq!(err.type_name, "invalid_request");
        assert_eq!(err.message, "invalid request");
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

        let (meta, body) =
            execute_request(request, None, None, None).expect("request should succeed");
        server.join().expect("server thread must join");

        assert_eq!(meta.status, 200);
        assert_eq!(body, b"ok");
        assert!(
            meta.headers
                .iter()
                .any(|(name, value)| name == "content-type" && value.0 == "text/plain")
        );

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

        let (meta, _body) = execute_request(request, Some(b"hello".to_vec()), None, None)
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

        let result = execute_request(request, None, None, None);
        server.join().expect("server thread must join");
        let error = result.expect_err("expected error");
        assert_eq!(error.type_name, "transport_error");
        assert_eq!(error.message, "request execution failed");
        assert_eq!(error.details["kind"], "timeout");
    }

    #[test]
    fn returns_econnrefused_kind_when_nothing_listens() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener must bind");
        let addr = listener.local_addr().expect("local addr");
        drop(listener);

        let mut request = base_request();
        request.url = format!("http://{addr}/");

        let error = execute_request(request, None, None, None).expect_err("expected error");
        assert_eq!(error.type_name, "transport_error");
        assert_eq!(error.details["kind"], "econnrefused");
    }

    #[test]
    fn returns_closed_kind_when_server_closes_before_responding() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener must bind");
        let addr = listener.local_addr().expect("local addr");
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("server must accept");
            let mut buffer = [0_u8; 1024];
            let _ = stream.read(&mut buffer);
        });

        let mut request = base_request();
        request.url = format!("http://{addr}/");

        let error = execute_request(request, None, None, None).expect_err("expected error");
        server.join().expect("server thread must join");
        assert_eq!(error.type_name, "transport_error");
        assert_eq!(error.details["kind"], "closed", "{:?}", error.details);
    }

    fn spawn_partial_body_server(hold_ms: u64) -> (String, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener must bind");
        let addr = listener.local_addr().expect("local addr");
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("server must accept");
            let mut buffer = [0_u8; 1024];
            let _ = stream.read(&mut buffer);
            let _ = stream.write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\nok");
            let _ = stream.flush();
            thread::sleep(StdDuration::from_millis(hold_ms));
        });
        (format!("http://{addr}/"), server)
    }

    #[test]
    fn returns_timeout_kind_when_body_stalls_past_receive_timeout() {
        let (url, server) = spawn_partial_body_server(400);

        let mut request = base_request();
        request.url = url;
        request.receive_timeout_ms = 150;

        let error = execute_request(request, None, None, None).expect_err("expected error");
        server.join().expect("server thread must join");
        assert_eq!(error.message, "failed to read response body");
        assert_eq!(error.details["kind"], "timeout", "{:?}", error.details);
    }

    #[test]
    fn body_that_outlasts_receive_timeout_succeeds_while_chunks_keep_arriving() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener must bind");
        let addr = listener.local_addr().expect("local addr");
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("server must accept");
            let mut buffer = [0_u8; 1024];
            let _ = stream.read(&mut buffer);
            let _ = stream.write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 60\r\n\r\n");
            for _ in 0..60 {
                thread::sleep(StdDuration::from_millis(20));
                let _ = stream.write_all(b"x");
                let _ = stream.flush();
            }
        });

        let mut request = base_request();
        request.url = format!("http://{addr}/");
        request.receive_timeout_ms = 1_000;

        let (meta, body) =
            execute_request(request, None, None, None).expect("request should succeed");
        server.join().expect("server thread must join");
        assert_eq!(meta.status, 200);
        assert_eq!(body, [b'x'; 60]);
    }

    #[test]
    fn returns_closed_kind_when_server_closes_mid_body() {
        let (url, server) = spawn_partial_body_server(0);

        let mut request = base_request();
        request.url = url;

        let error = execute_request(request, None, None, None).expect_err("expected error");
        server.join().expect("server thread must join");
        assert_eq!(error.message, "failed to read response body");
        assert_eq!(error.details["kind"], "closed", "{:?}", error.details);
    }

    #[test]
    #[ignore = "reaches thumbprint.me; run with task test:rust:external"]
    fn fingerprint_smoke_test_with_emulation() {
        let request = NativeRequest {
            method: "GET".to_string(),
            url: "https://thumbprint.me/api/v1/probe".to_string(),
            headers: vec![],
            receive_timeout_ms: 20_000,
            connect_timeout_ms: 30_000,
            proxy: None,
            emulation: Some("chrome_136".to_string()),
            insecure_skip_verify: false,
            max_body_size_bytes: None,
            local_address: None,
        };

        let (meta, body) =
            execute_request(request, None, None, None).expect("fingerprint request should succeed");
        assert!(meta.status >= 200 && meta.status < 300);

        let payload: serde_json::Value =
            serde_json::from_slice(&body).expect("response body must be JSON");

        assert!(payload.get("ja4").and_then(|v| v.as_str()).is_some());
        assert!(payload.get("ja4_r").and_then(|v| v.as_str()).is_some());
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

        let result = execute_request(request, None, None, None);
        server.join().expect("server thread must join");

        let err = result.expect_err("expected error");
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
            execute_request(request, None, None, None).expect("request should succeed");
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

        let (meta, body) =
            execute_request(request, None, None, None).expect("request should succeed");
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

        let (meta, response_body) = execute_request(request, None, None, None)
            .expect("request at exact limit should succeed");
        server.join().expect("server thread must join");

        assert_eq!(meta.status, 200);
        assert_eq!(response_body.len(), 100);
    }

    #[test]
    fn keeps_non_utf8_header_value_bytes() {
        let mut raw_response = Vec::new();
        raw_response.extend_from_slice(b"HTTP/1.1 200 OK\r\nx-binary: ");
        raw_response.extend_from_slice(&[0xff, 0xfe]);
        raw_response.extend_from_slice(b"\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok");
        let (url, _rx, server) = spawn_test_server(raw_response, 200);

        let mut request = base_request();
        request.url = url;

        let (meta, _body) =
            execute_request(request, None, None, None).expect("request should succeed");
        server.join().expect("server thread must join");

        let (_, value) = meta
            .headers
            .iter()
            .find(|(name, _)| name == "x-binary")
            .expect("x-binary header should exist");
        assert_eq!(value.0.as_bytes(), [0xff, 0xfe]);
    }

    // --- local_address tests ---

    #[test]
    fn rejects_invalid_local_address() {
        let mut request = base_request();
        request.local_address = Some("not-an-ip".to_string());

        let result = execute_request(request, None, None, None);
        let err = result.expect_err("expected error");
        assert_eq!(err.type_name, "invalid_request");
        assert_eq!(err.message, "invalid local_address");
    }

    #[test]
    fn accepts_loopback_local_address() {
        let response_body = "ok";
        let raw_response = format!(
            "HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
            response_body.len(),
            response_body
        )
        .into_bytes();
        let (url, _rx, server) = spawn_test_server(raw_response, 200);

        let mut request = base_request();
        request.url = url;
        request.local_address = Some("127.0.0.1".to_string());

        let (meta, body) =
            execute_request(request, None, None, None).expect("request should succeed");
        server.join().expect("server thread must join");

        assert_eq!(meta.status, 200);
        assert_eq!(body, b"ok");
    }

    // --- Client cache tests ---

    #[test]
    fn client_cache_is_bounded_under_distinct_keys() {
        // connect_timeout_ms is caller-controlled and part of the key. Feed more
        // distinct values than the cap and confirm the LRU never grows past it,
        // so a malicious or accidental rotation cannot leak Clients forever.
        for i in 0..(CLIENT_CACHE_CAP + 50) {
            let _ = build_client(None, false, 900_000 + i as u64, None).map(|client| {
                let mut cache = CLIENT_CACHE.lock().unwrap_or_else(|e| e.into_inner());
                cache.put((None, false, 900_000 + i as u64), client);
            });
        }

        let len = CLIENT_CACHE.lock().unwrap_or_else(|e| e.into_inner()).len();
        assert!(
            len <= CLIENT_CACHE_CAP,
            "cache grew to {len}, expected at most {CLIENT_CACHE_CAP}"
        );
    }

    // --- Pool client tests ---
    //
    // The pool request path is proven in the Elixir e2e suite, which loads the
    // real NIF. ResourceArc::new::<ClientResource>() cannot be constructed under
    // cargo test (the resource type is only registered in on_load, which the
    // test harness never runs), so these tests stay on build_client and
    // nif_new_pool's error mapping.

    #[test]
    fn build_client_accepts_pool_idle_timeout() {
        let result = build_client(Some("chrome_136"), false, 30_000, Some(5_000));
        assert!(result.is_ok(), "pool client with idle timeout should build");
    }

    #[test]
    fn build_client_rejects_unknown_emulation_profile() {
        let result = build_client(Some("unknown_browser"), false, 30_000, None);
        let err = result.map(drop).expect_err("expected error");
        assert_eq!(err.type_name, "invalid_request");
        assert_eq!(err.message, "unknown emulation profile");
    }

    // --- Cookie domain safety tests ---

    #[test]
    fn psl_rejects_public_suffix_domain() {
        let host = Some("www.example.com");
        assert!(cookie_for_jar(b"evil=1; Domain=com", host).is_none());
        assert!(cookie_for_jar(b"evil=1; Domain=CO.UK", host).is_none());
        assert!(cookie_for_jar(b"evil=1; Domain=.github.io", host).is_none());
    }

    #[test]
    fn psl_checks_the_last_domain_attribute_the_jar_stores() {
        let host = Some("www.example.com");
        assert!(cookie_for_jar(b"evil=1; Domain=example.com; Domain=com", host).is_none());
    }

    #[test]
    fn psl_accepts_registrable_domain() {
        let host = Some("www.example.com");
        let cookie = cookie_for_jar(b"x=1; Domain=.Example.co.uk", host).expect("kept");
        assert_eq!(cookie.domain(), Some("Example.co.uk"));
        assert!(cookie_for_jar(b"x=1; Domain=example.com", host).is_some());
    }

    #[test]
    fn psl_keeps_public_suffix_domain_equal_to_host_as_host_only() {
        let cookie = cookie_for_jar(b"sid=1; Domain=localhost", Some("localhost")).expect("kept");
        assert_eq!(cookie.domain(), None);
        let cookie = cookie_for_jar(b"sid=1; Domain=.Intranet", Some("intranet")).expect("kept");
        assert_eq!(cookie.domain(), None);
        assert!(cookie_for_jar(b"sid=1; Domain=localhost", Some("intranet")).is_none());
    }

    #[test]
    fn psl_accepts_host_only_cookie() {
        assert!(cookie_for_jar(b"session=abc; Path=/", Some("com")).is_some());
    }

    #[test]
    fn psl_rejects_non_utf8_header() {
        assert!(cookie_for_jar(&[0xff, 0xfe], Some("example.com")).is_none());
    }

    #[test]
    fn panic_error_keeps_the_panic_message() {
        let payload = std::panic::catch_unwind(|| panic!("boom")).expect_err("panics");
        assert_eq!(panic_error(&*payload).details["reason"], "boom");
        let payload = std::panic::catch_unwind(|| panic!("boom {}", 1)).expect_err("panics");
        assert_eq!(panic_error(&*payload).details["reason"], "boom 1");
    }
}
