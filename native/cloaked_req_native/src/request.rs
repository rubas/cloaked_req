use rustler::types::binary::Binary;
use rustler::{Decoder, NifMap, NifResult, Term};

/// A request header value as raw bytes, so a Latin-1 value goes out unchanged.
/// `HeaderValue` rejects the bytes that are invalid on the wire.
#[derive(Debug)]
pub struct RawHeaderBytes(pub Vec<u8>);

impl<'a> Decoder<'a> for RawHeaderBytes {
    fn decode(term: Term<'a>) -> NifResult<Self> {
        Ok(Self(Binary::from_term(term)?.as_slice().to_vec()))
    }
}

#[derive(Debug, NifMap)]
#[rustler(decode)]
pub struct NativeProxyConfig {
    pub url: String,
    pub headers: Vec<(String, RawHeaderBytes)>,
}

#[derive(Debug, NifMap)]
#[rustler(decode)]
pub struct NativeRequest {
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, RawHeaderBytes)>,
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
