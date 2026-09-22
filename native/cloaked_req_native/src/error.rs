use rustler::serde::SerdeTerm;
use rustler::{Encoder, Env, Term};
use serde_json::{Value, json};

#[derive(Debug)]
pub struct NativeError {
    pub type_name: &'static str,
    pub message: &'static str,
    pub details: Value,
}

impl NativeError {
    pub fn new(type_name: &'static str, message: &'static str, details: Value) -> Self {
        Self {
            type_name,
            message,
            details,
        }
    }
}

/// Encodes as a string-keyed map, which `CloakedReq.Native` turns into a
/// `%CloakedReq.Error{}`.
impl Encoder for NativeError {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        SerdeTerm(json!({
            "type": self.type_name,
            "message": self.message,
            "details": self.details,
        }))
        .encode(env)
    }
}
