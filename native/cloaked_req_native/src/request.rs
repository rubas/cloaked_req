use serde::Deserialize;

fn default_timeout_ms() -> u64 {
    30_000
}

#[derive(Debug, Deserialize)]
pub struct NativeRequest {
    pub method: String,
    pub url: String,
    #[serde(default)]
    pub headers: Vec<[String; 2]>,
    #[serde(default)]
    pub body_base64: Option<String>,
    #[serde(default = "default_timeout_ms")]
    pub receive_timeout_ms: u64,
    #[serde(default)]
    pub emulation: Option<String>,
    #[serde(default)]
    pub insecure_skip_verify: bool,
    #[serde(default)]
    pub max_body_size_bytes: Option<u64>,
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
        assert!(request.body_base64.is_none());
        assert_eq!(request.receive_timeout_ms, 30_000);
        assert!(request.emulation.is_none());
        assert!(!request.insecure_skip_verify);
        assert!(request.max_body_size_bytes.is_none());
    }

    #[test]
    fn deserializes_full_request_shape() {
        let request: NativeRequest = serde_json::from_str(
            r#"{
              "method": "POST",
              "url": "https://example.com/path",
              "headers": [["x-demo", "1"], ["content-type", "application/json"]],
              "body_base64": "eyJvayI6dHJ1ZX0=",
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
        assert_eq!(request.body_base64.as_deref(), Some("eyJvayI6dHJ1ZX0="));
        assert_eq!(request.receive_timeout_ms, 5_000);
        assert_eq!(request.emulation.as_deref(), Some("chrome_136"));
        assert!(request.insecure_skip_verify);
        assert_eq!(request.max_body_size_bytes, Some(10_485_760));
    }
}
