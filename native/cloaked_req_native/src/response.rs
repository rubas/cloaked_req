use rustler::types::binary::{Binary, NewBinary};
use rustler::{Encoder, Env, NifMap, Term};
use wreq::header::HeaderValue;

/// A response header value as the raw bytes the server sent, so a Latin-1
/// value such as a `content-disposition` file name reaches Elixir unchanged.
#[derive(Debug)]
pub struct RawHeaderValue(pub HeaderValue);

impl Encoder for RawHeaderValue {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        let bytes = self.0.as_bytes();
        let mut binary = NewBinary::new(env, bytes.len());
        binary.as_mut_slice().copy_from_slice(bytes);
        Binary::from(binary).encode(env)
    }
}

#[derive(Debug, NifMap)]
#[rustler(encode)]
pub struct NativeResponseMeta {
    pub status: u16,
    pub url: String,
    pub headers: Vec<(String, RawHeaderValue)>,
}
