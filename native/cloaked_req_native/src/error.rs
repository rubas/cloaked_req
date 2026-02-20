use serde::Serialize;
use serde_json::{json, Value};

#[derive(Debug, Serialize)]
pub struct NativeError {
    #[serde(rename = "type")]
    pub type_name: String,
    pub message: String,
    pub details: Value,
}

impl NativeError {
    pub fn new(type_name: &str, message: &str, details: Value) -> Self {
        Self {
            type_name: type_name.to_string(),
            message: message.to_string(),
            details,
        }
    }

    /// Serializes as JSON string. Used as fallback when SerdeTerm encoding is unavailable
    /// (e.g. panic recovery path where we can't access the NIF Env).
    #[allow(dead_code)]
    pub fn encode(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| {
            json!({
                "type": "native_error",
                "message": "failed to serialize native error",
                "details": {}
            })
            .to_string()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::NativeError;
    use serde_json::json;

    #[test]
    fn encode_serializes_expected_shape() {
        let error = NativeError::new(
            "invalid_request",
            "invalid HTTP method",
            json!({"value": "BAD METHOD"}),
        );

        let encoded = error.encode();
        let decoded: serde_json::Value =
            serde_json::from_str(&encoded).expect("error JSON should decode");

        assert_eq!(decoded["type"], "invalid_request");
        assert_eq!(decoded["message"], "invalid HTTP method");
        assert_eq!(decoded["details"]["value"], "BAD METHOD");
    }

    #[test]
    fn encode_handles_empty_message() {
        let error = NativeError::new("native_error", "", json!({}));

        let encoded = error.encode();
        let decoded: serde_json::Value =
            serde_json::from_str(&encoded).expect("error JSON should decode");

        assert_eq!(decoded["type"], "native_error");
        assert_eq!(decoded["message"], "");
        assert!(decoded["details"].as_object().unwrap().is_empty());
    }

    #[test]
    fn encode_handles_nested_details() {
        let error = NativeError::new(
            "transport_error",
            "connection failed",
            json!({
                "reason": "timeout",
                "debug": "hyper::Error(Connect, ConnectError(\"tcp connect error\"))",
                "context": {
                    "host": "example.com",
                    "port": 443,
                    "attempts": [1, 2, 3]
                }
            }),
        );

        let encoded = error.encode();
        let decoded: serde_json::Value =
            serde_json::from_str(&encoded).expect("error JSON should decode");

        assert_eq!(decoded["type"], "transport_error");
        assert_eq!(decoded["details"]["reason"], "timeout");
        assert_eq!(decoded["details"]["context"]["host"], "example.com");
        assert_eq!(decoded["details"]["context"]["port"], 443);
        assert_eq!(
            decoded["details"]["context"]["attempts"]
                .as_array()
                .unwrap()
                .len(),
            3
        );
    }
}
