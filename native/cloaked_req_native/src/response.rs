use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct NativeResponse {
    pub status: u16,
    pub url: String,
    pub headers: Vec<[String; 2]>,
    pub body_base64: String,
}

#[cfg(test)]
mod tests {
    use super::NativeResponse;

    #[test]
    fn serializes_expected_shape() {
        let response = NativeResponse {
            status: 200,
            url: "https://example.com/path".to_string(),
            headers: vec![
                ["content-type".to_string(), "text/plain".to_string()],
                ["x-request-id".to_string(), "abc-123".to_string()],
            ],
            body_base64: "aGVsbG8=".to_string(),
        };

        let json = serde_json::to_string(&response).expect("should serialize");
        let decoded: serde_json::Value =
            serde_json::from_str(&json).expect("should parse back");

        assert_eq!(decoded["status"], 200);
        assert_eq!(decoded["url"], "https://example.com/path");
        assert_eq!(decoded["headers"][0][0], "content-type");
        assert_eq!(decoded["headers"][0][1], "text/plain");
        assert_eq!(decoded["headers"][1][0], "x-request-id");
        assert_eq!(decoded["headers"][1][1], "abc-123");
        assert_eq!(decoded["body_base64"], "aGVsbG8=");
    }

    #[test]
    fn serializes_empty_body_and_no_headers() {
        let response = NativeResponse {
            status: 204,
            url: "https://example.com".to_string(),
            headers: vec![],
            body_base64: "".to_string(),
        };

        let json = serde_json::to_string(&response).expect("should serialize");
        let decoded: serde_json::Value =
            serde_json::from_str(&json).expect("should parse back");

        assert_eq!(decoded["status"], 204);
        assert_eq!(decoded["headers"].as_array().unwrap().len(), 0);
        assert_eq!(decoded["body_base64"], "");
    }

    #[test]
    fn serializes_many_headers() {
        let headers: Vec<[String; 2]> = (0..50)
            .map(|i| [format!("x-header-{i}"), format!("value-{i}")])
            .collect();

        let response = NativeResponse {
            status: 200,
            url: "https://example.com".to_string(),
            headers,
            body_base64: "".to_string(),
        };

        let json = serde_json::to_string(&response).expect("should serialize");
        let decoded: serde_json::Value =
            serde_json::from_str(&json).expect("should parse back");

        let parsed_headers = decoded["headers"].as_array().unwrap();
        assert_eq!(parsed_headers.len(), 50);
        assert_eq!(parsed_headers[0][0], "x-header-0");
        assert_eq!(parsed_headers[49][0], "x-header-49");
        assert_eq!(parsed_headers[49][1], "value-49");
    }
}
