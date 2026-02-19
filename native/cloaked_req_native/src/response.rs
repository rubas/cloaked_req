use rustler::NifMap;
use serde::Serialize;

#[derive(Debug, Serialize, NifMap)]
pub struct NativeResponseMeta {
    pub status: u16,
    pub url: String,
    pub headers: Vec<(String, String)>,
}

#[cfg(test)]
mod tests {
    use super::NativeResponseMeta;

    #[test]
    fn serializes_expected_shape() {
        let meta = NativeResponseMeta {
            status: 200,
            url: "https://example.com/path".to_string(),
            headers: vec![
                ("content-type".to_string(), "text/plain".to_string()),
                ("x-request-id".to_string(), "abc-123".to_string()),
            ],
        };

        let json = serde_json::to_string(&meta).expect("should serialize");
        let decoded: serde_json::Value = serde_json::from_str(&json).expect("should parse back");

        assert_eq!(decoded["status"], 200);
        assert_eq!(decoded["url"], "https://example.com/path");
        assert_eq!(decoded["headers"][0][0], "content-type");
        assert_eq!(decoded["headers"][0][1], "text/plain");
        assert_eq!(decoded["headers"][1][0], "x-request-id");
        assert_eq!(decoded["headers"][1][1], "abc-123");
    }

    #[test]
    fn serializes_no_headers() {
        let meta = NativeResponseMeta {
            status: 204,
            url: "https://example.com".to_string(),
            headers: vec![],
        };

        let json = serde_json::to_string(&meta).expect("should serialize");
        let decoded: serde_json::Value = serde_json::from_str(&json).expect("should parse back");

        assert_eq!(decoded["status"], 204);
        assert_eq!(decoded["headers"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn serializes_many_headers() {
        let headers: Vec<(String, String)> = (0..50)
            .map(|i| (format!("x-header-{i}"), format!("value-{i}")))
            .collect();

        let meta = NativeResponseMeta {
            status: 200,
            url: "https://example.com".to_string(),
            headers,
        };

        let json = serde_json::to_string(&meta).expect("should serialize");
        let decoded: serde_json::Value = serde_json::from_str(&json).expect("should parse back");

        let parsed_headers = decoded["headers"].as_array().unwrap();
        assert_eq!(parsed_headers.len(), 50);
        assert_eq!(parsed_headers[0][0], "x-header-0");
        assert_eq!(parsed_headers[49][0], "x-header-49");
        assert_eq!(parsed_headers[49][1], "value-49");
    }
}
