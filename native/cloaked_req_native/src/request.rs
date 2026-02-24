use rustler::NifMap;
use serde::Deserialize;

fn default_timeout_ms() -> u64 {
    30_000
}

#[derive(Debug, Deserialize, NifMap)]
pub struct NativeRequest {
    pub method: String,
    pub url: String,
    #[serde(default)]
    pub headers: Vec<(String, String)>,
    #[serde(default = "default_timeout_ms")]
    pub receive_timeout_ms: u64,
    #[serde(default)]
    pub emulation: Option<String>,
    #[serde(default)]
    pub insecure_skip_verify: bool,
    #[serde(default)]
    pub max_body_size_bytes: Option<u64>,
    #[serde(default)]
    pub local_address: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::NativeRequest;

    #[test]
    fn deserializes_minimal_request_with_defaults() {
        let request: NativeRequest = serde_json::from_str(
            r#"{
              "method": "GET",
              "url": "https://example.com"
            }"#,
        )
        .expect("request should deserialize");

        assert_eq!(request.method, "GET");
        assert_eq!(request.url, "https://example.com");
        assert!(request.headers.is_empty());
        assert_eq!(request.receive_timeout_ms, 30_000);
        assert!(request.emulation.is_none());
        assert!(!request.insecure_skip_verify);
        assert!(request.max_body_size_bytes.is_none());
        assert!(request.local_address.is_none());
    }

    #[test]
    fn deserializes_full_request_shape() {
        let request: NativeRequest = serde_json::from_str(
            r#"{
              "method": "POST",
              "url": "https://example.com/path",
              "headers": [["x-demo", "1"], ["content-type", "application/json"]],
              "receive_timeout_ms": 5000,
              "emulation": "chrome_136",
              "insecure_skip_verify": true,
              "max_body_size_bytes": 10485760
            }"#,
        )
        .expect("request should deserialize");

        assert_eq!(request.method, "POST");
        assert_eq!(request.url, "https://example.com/path");
        assert_eq!(request.headers.len(), 2);
        assert_eq!(request.receive_timeout_ms, 5_000);
        assert_eq!(request.emulation.as_deref(), Some("chrome_136"));
        assert!(request.insecure_skip_verify);
        assert_eq!(request.max_body_size_bytes, Some(10_485_760));
        assert!(request.local_address.is_none());
    }

    #[test]
    fn deserializes_ipv4_local_address() {
        let request: NativeRequest = serde_json::from_str(
            r#"{
              "method": "GET",
              "url": "https://example.com",
              "local_address": "192.168.1.1"
            }"#,
        )
        .expect("request should deserialize");

        assert_eq!(request.local_address.as_deref(), Some("192.168.1.1"));
    }

    #[test]
    fn deserializes_ipv6_local_address() {
        let request: NativeRequest = serde_json::from_str(
            r#"{
              "method": "GET",
              "url": "https://example.com",
              "local_address": "::1"
            }"#,
        )
        .expect("request should deserialize");

        assert_eq!(request.local_address.as_deref(), Some("::1"));
    }
}
