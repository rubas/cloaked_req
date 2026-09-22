use rustler::NifMap;

#[derive(Debug, NifMap)]
#[rustler(decode)]
pub struct NativeProxyConfig {
    pub url: String,
    pub headers: Vec<(String, String)>,
}

#[derive(Debug, NifMap)]
#[rustler(decode)]
pub struct NativeRequest {
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub receive_timeout_ms: u64,
    pub connect_timeout_ms: u64,
    pub proxy: Option<NativeProxyConfig>,
    pub emulation: Option<String>,
    pub insecure_skip_verify: bool,
    pub max_body_size_bytes: Option<u64>,
    pub local_address: Option<String>,
}

#[derive(Debug, NifMap)]
#[rustler(decode)]
pub struct NativePoolConfig {
    pub emulation: Option<String>,
    pub insecure_skip_verify: bool,
    pub connect_timeout_ms: u64,
    pub pool_idle_timeout_ms: Option<u64>,
}
